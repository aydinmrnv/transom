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
    private let queue = DispatchQueue(label: "one.transom.host.capture")

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

    public init(display: DisplayInfo, fps: Int = 60) {
        self.display = display
        self.fps = fps
        super.init()
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

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])

        let config = SCStreamConfiguration()
        // The load-bearing lines for I-1: exact native pixels, no scaling.
        config.width = display.pixelWidth
        config.height = display.pixelHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 5
        config.showsCursor = true
        config.scalesToFit = false

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
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
    }

    /// Latest frame as a CGImage, converted on demand. Nil until the first
    /// complete frame arrives.
    public func latestImage() -> CGImage? {
        lock.withLock {
            guard let buffer = latestPixelBuffer else { return nil }
            return ciContext.createCGImage(
                CIImage(cvPixelBuffer: buffer),
                from: CGRect(
                    x: 0, y: 0,
                    width: CVPixelBufferGetWidth(buffer),
                    height: CVPixelBufferGetHeight(buffer)))
        }
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

        let (ctx, frameHook, pixelHook):
            (
                CIContext, (@Sendable (CGImage) -> Void)?,
                (@Sendable (CVPixelBuffer, CMTime) -> Void)?
            ) = lock.withLock {
                latestPixelBuffer = pixelBuffer
                _stats = stats
                return (ciContext, onFrame, onPixelBuffer)
            }

        // Zero-copy tap first: hand the raw IOSurface buffer straight to the
        // encoder before spending anything on the CGImage path (I-1). Signposted
        // so the capture→handoff interval is measurable in Instruments.
        if let pixelHook {
            let signpostState = Log.signposter.beginInterval("capture")
            pixelHook(pixelBuffer, sampleBuffer.presentationTimeStamp)
            Log.signposter.endInterval("capture", signpostState)
        }

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

    public var description: String {
        switch self {
        case .displayNotFound(let id):
            return "ScreenCaptureKit does not see display id \(id)."
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
