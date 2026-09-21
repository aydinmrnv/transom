import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// A single ScreenCaptureKit display stream, configured at the display's
/// **native pixel size** so that SCK space == the display's pixel space (I-1).
///
/// This is the shared capture primitive behind both the `capture`/`probe` CLI
/// commands and the app's live probe view. It never scales: the stream config
/// width/height are set to the display's exact pixel dimensions, and the command
/// layer verifies the delivered buffer matches (a mismatch means SCK is scaling
/// and I-1 is already violated).
public final class DisplayCapture: NSObject, SCStreamOutput, @unchecked Sendable {

    /// What SCK was actually configured and is delivering, for I-1 verification.
    public struct FrameStats: Sendable {
        public let configuredWidth: Int
        public let configuredHeight: Int
        public let deliveredWidth: Int
        public let deliveredHeight: Int
        public let pixelFormat: OSType
        public var pixelFormatString: String { fourCC(pixelFormat) }
        /// True iff the delivered buffer matches the display's native pixel size.
        public let matchesNativePixels: Bool
    }

    private let display: DisplayInfo
    private let fps: Int
    private let applicationPIDs: Set<pid_t>?
    private let pixelFormat: OSType
    private var selectedWindows: [SCWindow]?
    private let queue = DispatchQueue(label: "one.transom.host.capture")
    // Accessed only on the capture queue, including explicit refreshes.
    private var lastPixelPTS = CMTime.invalid
    private var lastEmission = DispatchTime.now().uptimeNanoseconds

    private let lock = NSLock()
    private var stream: SCStream?
    private var latestPixelBuffer: CVPixelBuffer?
    private var _stats: FrameStats?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Optional per-frame hook, called on the capture queue with a fresh CGImage.
    /// Used by the app's live view. Leave nil for the CLI's poll-on-demand model.
    public var onFrame: (@Sendable (CGImage) -> Void)?

    /// Optional per-frame hook, called on the capture queue with the **raw**
    /// IOSurface-backed pixel buffer and its presentation timestamp — the
    /// zero-copy entry point for the encoder (issue #3 Phase 2). Unlike `onFrame`,
    /// this never touches `CGImage`, so nothing round-trips through the CPU (I-1
    /// pipeline note). The buffer belongs to SCK's pool; use it **synchronously**
    /// (encode it now). Do not retain it past the call or the pool may recycle it
    /// underneath you.
    public var onPixelBuffer: (@Sendable (CVPixelBuffer, CMTime) -> Void)?

    public init(
        display: DisplayInfo, fps: Int = 60, applicationPIDs: Set<pid_t>? = nil,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA, selectedWindows: [SCWindow]? = nil
    ) {
        self.display = display
        self.fps = fps
        self.applicationPIDs = applicationPIDs
        self.pixelFormat = pixelFormat
        self.selectedWindows = selectedWindows
        super.init()
    }

    /// Called serially by WindowBrowser; the capture queue only reads pixels.
    public func selectWindows(_ windows: [SCWindow]) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }),
            let stream = lock.withLock({ stream }) else { throw CaptureError.displayNotFound(display.id) }
        try await stream.updateContentFilter(SCContentFilter(display: scDisplay, including: windows))
        lock.withLock { selectedWindows = windows }
    }

    public func removeWindow(_ id: CGWindowID) async throws {
        let windows = lock.withLock { selectedWindows?.filter { $0.windowID != id } ?? [] }
        try await selectWindows(windows)
    }

    /// Stats from the most recent delivered frame, if any.
    public var stats: FrameStats? {
        lock.withLock { _stats }
    }

    /// Start the stream. Throws if SCK cannot see the display or Screen Recording
    /// permission is absent.
    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id })
        else {
            throw CaptureError.displayNotFound(display.id)
        }

        let filter: SCContentFilter
        if let selectedWindows {
            filter = SCContentFilter(display: scDisplay, including: selectedWindows)
        } else if let applicationPIDs {
            // Inclusion, not exclusion: other apps, the desktop and this host's
            // own panel must never appear inside a selected window's crop.
            let applications = content.applications.filter { applicationPIDs.contains($0.processID) }
            guard !applications.isEmpty else { throw CaptureError.noSelectedApplications }
            filter = SCContentFilter(display: scDisplay, including: applications, exceptingWindows: [])
        } else {
            // Whole-display capture is reserved for the diagnostic CLI/probe.
            filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        }

        let config = SCStreamConfiguration()
        // The load-bearing lines for I-1: exact native pixels, no scaling.
        config.width = display.pixelWidth
        config.height = display.pixelHeight
        config.pixelFormat = pixelFormat
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // The direct NV12 encoder and the idle-frame cache retain surfaces.
        // Leave enough capture surfaces available while those GPU jobs finish;
        // this is a surface pool, not an encoded-frame playback queue.
        config.queueDepth = 5
        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            config.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
            config.colorSpaceName = CGColorSpace.sRGB
        }
        // Cursor position is rendered locally by Windows, outside the video delay.
        config.showsCursor = false
        config.scalesToFit = false
        // ScreenCaptureKit declares backgroundColor as unowned(unsafe). Keep the
        // CGColor alive through SCStream's configuration copy; releasing the
        // temporary immediately after assignment leaves a dangling pointer and
        // crashes in CGColorCreateCopy when the app starts capture in the
        // background.
        let backgroundColor = CGColor(gray: 0, alpha: 1)
        config.backgroundColor = backgroundColor

        let stream = withExtendedLifetime(backgroundColor) {
            SCStream(filter: filter, configuration: config, delegate: nil)
        }
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        lock.withLock { self.stream = stream }
    }

    public func stop() async {
        let s: SCStream? = lock.withLock {
            let current = stream
            stream = nil
            return current
        }
        if let s { try? await s.stopCapture() }
        // Drain an in-flight explicit refresh before the caller finishes the
        // encoder. Refreshes queued after this observe stream == nil.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    /// SCK emits no complete frames while a display is idle. Feed its retained
    /// native-size image through the encoder on connect, then once more to
    /// release a decoder's one-frame pipeline delay. This changes no Mac UI.
    public func requestRefresh() {
        queue.async { [weak self] in self?.refreshOnCaptureQueue() }
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.refreshOnCaptureQueue()
        }
    }

    /// SCK stops producing complete samples when the screen settles. A decoder
    /// can still hold the final frame, or be waiting for a recovery keyframe.
    /// Keep idle sessions advancing without increasing an active stream's FPS.
    public func requestIdleRefresh() {
        queue.async { [weak self] in
            guard let self,
                DispatchTime.now().uptimeNanoseconds - self.lastEmission >= 250_000_000
            else { return }
            self.refreshOnCaptureQueue()
        }
    }

    private func refreshOnCaptureQueue() {
        let buffer = lock.withLock { stream == nil ? nil : latestPixelBuffer }
        guard let buffer else { return }
        emitPixelBuffer(buffer, pts: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    private func emitPixelBuffer(_ buffer: CVPixelBuffer, pts: CMTime) {
        guard let pixelHook = onPixelBuffer else { return }
        // A captured sample can have been queued before an explicit refresh.
        // Keep encoder timestamps monotonic without altering any pixels.
        let timestamp = lastPixelPTS.isValid && CMTimeCompare(pts, lastPixelPTS) <= 0
            ? CMTimeAdd(lastPixelPTS, CMTime(value: 1, timescale: 1_000_000)) : pts
        lastPixelPTS = timestamp
        lastEmission = DispatchTime.now().uptimeNanoseconds
        let signpostState = Log.signposter.beginInterval("capture")
        pixelHook(buffer, timestamp)
        Log.signposter.endInterval("capture", signpostState)
    }

    /// Latest frame converted on demand. The default keeps native pixels;
    /// maxPixelWidth is only for selector thumbnails, never interactive video.
    /// Nil until the first complete frame arrives.
    ///
    /// The IOSurface-backed buffer is grabbed under the lock and the (potentially
    /// expensive) `createCGImage` runs **outside** it — holding a strong ref keeps
    /// the buffer alive against pool recycling, exactly as the capture callback's
    /// own `onFrame` render does — so a 60fps capture callback is never blocked
    /// waiting on a preview conversion.
    public func latestImage(maxPixelWidth: Int? = nil) -> CGImage? {
        let (buffer, ctx): (CVPixelBuffer?, CIContext) = lock.withLock {
            (latestPixelBuffer, ciContext)
        }
        guard let buffer else { return nil }
        var image = CIImage(cvPixelBuffer: buffer)
        // This optional reduction is exclusively for the host's selector UI.
        // The capture→encoder path above always retains native pixels.
        if let maxPixelWidth, maxPixelWidth > 0, image.extent.width > CGFloat(maxPixelWidth) {
            let scale = CGFloat(maxPixelWidth) / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return ctx.createCGImage(image, from: image.extent.integral)
    }

    // MARK: - SCStreamOutput

    public func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Only act on complete frames; SCK also emits idle/blank status frames.
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw),
            status == .complete
        else { return }

        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let dw = CVPixelBufferGetWidth(pixelBuffer)
        let dh = CVPixelBufferGetHeight(pixelBuffer)
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let stats = FrameStats(
            configuredWidth: display.pixelWidth,
            configuredHeight: display.pixelHeight,
            deliveredWidth: dw,
            deliveredHeight: dh,
            pixelFormat: fmt,
            matchesNativePixels: dw == display.pixelWidth && dh == display.pixelHeight)

        let (ctx, frameHook):
            (
                CIContext, (@Sendable (CGImage) -> Void)?
            ) = lock.withLock {
                latestPixelBuffer = pixelBuffer
                _stats = stats
                return (ciContext, onFrame)
            }

        // Zero-copy tap first: hand the raw IOSurface buffer straight to the
        // encoder before spending anything on the CGImage path (I-1). Signposted
        // so the capture→handoff interval is measurable in Instruments.
        emitPixelBuffer(pixelBuffer, pts: sampleBuffer.presentationTimeStamp)

        if let frameHook {
            let image = ctx.createCGImage(
                CIImage(cvPixelBuffer: pixelBuffer),
                from: CGRect(x: 0, y: 0, width: dw, height: dh))
            if let image { frameHook(image) }
        }
    }
}

public enum CaptureError: Error, CustomStringConvertible {
    case displayNotFound(CGDirectDisplayID)
    case noSelectedApplications

    public var description: String {
        switch self {
        case .displayNotFound(let id):
            return "ScreenCaptureKit does not see display id \(id)."
        case .noSelectedApplications:
            return "ScreenCaptureKit cannot find the selected apps. Open an app window and try again."
        }
    }
}

/// Decode a four-character-code OSType (e.g. a CoreVideo pixel format) into its
/// printable form like `BGRA`.
public func fourCC(_ code: OSType) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF),
    ]
    let scalars = bytes.map { Character(UnicodeScalar($0)) }
    let s = String(scalars).trimmingCharacters(in: .whitespaces)
    return s.isEmpty ? String(code) : "\(s) (0x\(String(code, radix: 16)))"
}
