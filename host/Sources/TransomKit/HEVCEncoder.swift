import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

/// The HEVC encoder for the capture pipeline (issue #3 Phase 2).
///
/// The chroma/bit-depth is **selectable** (`Format`), because the two ends of the
/// system disagree about what is decodable vs. what looks best (see
/// `docs/protocol.md` §6-7):
///
/// * **`.hevc420_8bit`** (the default) is HEVC Main 4:2:0 8-bit. It is what the
///   Windows client's in-box Media Foundation H.265 decoder can actually decode
///   (Main/Main10 4:2:0 → NV12), so real pixels appear on the client with no extra
///   decoder. Chroma subsampling softens colored text a little; a picture that
///   shows beats a crisp one that cannot decode.
/// * **`.hevc444_10bit`** is HEVC 4:4:4 10-bit through the `v410` source path
///   (OQ-4), the crisp-text quality target — but the in-box Windows decoder cannot
///   decode 4:4:4, so it needs a 4:4:4-capable client decoder before it shows
///   anything.
///
/// SCK hands us `BGRA`, so this type owns two VideoToolbox sessions:
///
/// 1. a `VTPixelTransferSession` that converts each captured `BGRA` IOSurface into
///    the format's source IOSurface (a color-space conversion on the media
///    engine — **not** a spatial resample, so I-1 holds — and never a round-trip
///    through `CGImage` or `Data`), and
/// 2. a `VTCompressionSession` that encodes those frames, hardware **required** (we
///    proved it works, so a fall to software is a startup error, not a silent
///    quality cliff).
///
/// ### Concurrency
/// This class holds VideoToolbox session references, which are not `Sendable`, so
/// it cannot be checked `Sendable` by the compiler. It is `@unchecked Sendable`
/// on a real, documented invariant, **not** to paper over a race: `encode` is
/// only ever called from a single serial queue (the capture queue), and the
/// session state is otherwise immutable after `init`. The one place VideoToolbox
/// calls back on its own thread — the per-frame output handler — touches only the
/// caller's `onEncodedFrame` closure, which the caller is responsible for making
/// thread-safe. There is no shared mutable state to race on here.
public final class HEVCEncoder: @unchecked Sendable {

    /// One encoded HEVC access unit. `byteCount` is the compressed size — the
    /// number that, summed over a second, is the bitrate. `data` is the elementary
    /// stream bytes for the wire (empty when the caller only needs the size).
    public struct EncodedFrame: Sendable {
        public let byteCount: Int
        public let pts: CMTime
        public let isKeyframe: Bool
        public let data: Data
    }

    /// The chroma / bit-depth the stream is encoded at. The default is the mode
    /// the Windows in-box decoder can decode; 4:4:4 is the quality target. See the
    /// type doc above and `docs/protocol.md` §6-7.
    public enum Format: String, Sendable, CaseIterable {
        /// HEVC Main 4:2:0 8-bit — decodable by the client's in-box MF decoder.
        case hevc420_8bit
        /// HEVC 4:4:4 10-bit (v410) — crisp text, needs a 4:4:4-capable decoder.
        case hevc444_10bit

        /// The CoreVideo pixel format captured `BGRA` is converted into before the
        /// compression session. 4:2:0 uses **video-range** so the client's
        /// limited-range NV12→BGRA math lines up; 4:4:4 uses `v410`.
        var sourcePixelFormat: OSType {
            switch self {
            case .hevc420_8bit: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            case .hevc444_10bit: return kCVPixelFormatType_444YpCbCr10
            }
        }

        /// The HEVC profile to pin, or `nil` to let VideoToolbox derive it from the
        /// source pixel format. 4:4:4 has no public profile constant (OQ-4), so it
        /// must be derived; 4:2:0 pins Main so the client sees a plain Main stream.
        var profileLevel: CFString? {
            switch self {
            case .hevc420_8bit: return kVTProfileLevel_HEVC_Main_AutoLevel
            case .hevc444_10bit: return nil
            }
        }

        /// Short chroma tag for logs / status (e.g. "4:2:0 8-bit").
        public var chromaTag: String {
            switch self {
            case .hevc420_8bit: return "4:2:0 8-bit"
            case .hevc444_10bit: return "4:4:4 10-bit"
            }
        }

        /// Whether the Windows in-box HEVC decoder can decode this stream as-is.
        public var inBoxDecodable: Bool {
            switch self {
            case .hevc420_8bit: return true
            case .hevc444_10bit: return false
            }
        }

        /// Parse a short CLI token ("420" / "444"), else nil.
        public init?(cliToken: String) {
            switch cliToken.lowercased() {
            case "420", "4:2:0", "420_8bit": self = .hevc420_8bit
            case "444", "4:4:4", "444_10bit": self = .hevc444_10bit
            default: return nil
            }
        }
    }

    public struct Config: Sendable {
        public var width: Int
        public var height: Int
        public var fps: Int
        public var bitrateBitsPerSecond: Int
        public var maxKeyFrameInterval: Int
        public var format: Format

        public init(
            width: Int, height: Int, fps: Int = 60,
            bitrateBitsPerSecond: Int = 40_000_000, maxKeyFrameInterval: Int = 120,
            format: Format = .hevc420_8bit
        ) {
            self.width = width
            self.height = height
            self.fps = fps
            self.bitrateBitsPerSecond = bitrateBitsPerSecond
            self.maxKeyFrameInterval = maxKeyFrameInterval
            self.format = format
        }
    }

    public enum EncoderError: Error, CustomStringConvertible {
        case pixelBufferPoolCreateFailed(CVReturn)
        case pixelTransferSessionCreateFailed(OSStatus)
        case compressionSessionCreateFailed(OSStatus)
        case prepareFailed(OSStatus)
        case v410AllocationFailed(CVReturn)
        case transferFailed(OSStatus)
        case encodeFailed(OSStatus)

        public var description: String {
            switch self {
            case .pixelBufferPoolCreateFailed(let s):
                return "could not create the v410 pixel-buffer pool (CVReturn \(s))"
            case .pixelTransferSessionCreateFailed(let s):
                return "could not create the BGRA→v410 pixel-transfer session (OSStatus \(s))"
            case .compressionSessionCreateFailed(let s):
                return
                    "could not create the HEVC hardware compression session (OSStatus \(s)); "
                    + "the hardware encoder may be unavailable"
            case .prepareFailed(let s):
                return "VTCompressionSessionPrepareToEncodeFrames failed (OSStatus \(s))"
            case .v410AllocationFailed(let s):
                return "could not allocate a v410 destination buffer (CVReturn \(s))"
            case .transferFailed(let s):
                return "BGRA→v410 pixel transfer failed (OSStatus \(s))"
            case .encodeFailed(let s):
                return "VTCompressionSessionEncodeFrame failed (OSStatus \(s))"
            }
        }
    }

    /// Called once per encoded frame. May be invoked on a VideoToolbox-internal
    /// thread, so the closure must be thread-safe.
    public var onEncodedFrame: (@Sendable (EncodedFrame) -> Void)?

    /// When true, each `EncodedFrame` carries the compressed `data` bytes (the
    /// wire path needs them). When false — the default — only sizes are collected,
    /// so the measurement path (`encode`) does not pay for a copy it discards. Set
    /// before the first frame; it is read on the VideoToolbox callback thread.
    public var extractFrameData = false

    /// VideoToolbox's own read-back of whether the compression session is running
    /// on the hardware encoder. Populated at `init`.
    public private(set) var usingHardware = false

    /// The HEVC parameter sets (`hvcC` configuration record) from the encoded
    /// stream's format description, captured on the first frame. The decoder needs
    /// these before it can decode any frame (they are not inline in `hvc1`), so
    /// the video server sends them to the client before the first frame.
    public private(set) var parameterSetsHVCC: Data?

    /// The codec + chroma the compression session reports it is producing, for
    /// I-1 / OQ-4 verification (e.g. "HEVC 4:4:4").
    public private(set) var outputFormatSummary = "unknown"

    private let config: Config
    private let compression: VTCompressionSession
    private let transfer: VTPixelTransferSession
    private let v410Pool: CVPixelBufferPool

    public init(config: Config) throws {
        self.config = config

        // 1. A pool of source (e.g. v410 for 4:4:4, or NV12 for 4:2:0) IOSurface
        //    buffers to convert into, in the configured format's pixel format.
        let sourcePixelFormat = config.format.sourcePixelFormat
        let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 3]
        let bufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: sourcePixelFormat,
            kCVPixelBufferWidthKey: config.width,
            kCVPixelBufferHeightKey: config.height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(
            kCFAllocatorDefault, poolAttrs as CFDictionary, bufferAttrs as CFDictionary, &pool)
        guard poolStatus == kCVReturnSuccess, let pool else {
            throw EncoderError.pixelBufferPoolCreateFailed(poolStatus)
        }
        self.v410Pool = pool

        // 2. The BGRA→v410 transfer session (color conversion on the media engine).
        var transferSession: VTPixelTransferSession?
        let transferStatus = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession)
        guard transferStatus == noErr, let transferSession else {
            throw EncoderError.pixelTransferSessionCreateFailed(transferStatus)
        }
        // Tell the transfer how to take RGB to YCbCr: Rec. 709, full 4:4:4.
        VTSessionSetProperty(
            transferSession, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries,
            value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(
            transferSession, key: kVTPixelTransferPropertyKey_DestinationTransferFunction,
            value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(
            transferSession, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
            value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        self.transfer = transferSession

        // 3. The HEVC compression session, hardware REQUIRED. We proved 4:4:4
        //    10-bit encodes in hardware (Phase 0); requiring it turns any silent
        //    software fall into a loud startup failure instead of a quality cliff.
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        // Hint the source format so VideoToolbox derives the right profile. For
        // 4:4:4 we deliberately do NOT set kVTCompressionPropertyKey_ProfileLevel:
        // there is no public 4:4:4 constant, and setting Main42210 would silently
        // force 4:2:2 (Phase 0). For 4:2:0 we pin Main below (see `configure`).
        let sourceAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: sourcePixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
            kCVPixelBufferWidthKey: config.width,
            kCVPixelBufferHeightKey: config.height,
        ]
        var session: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(config.width),
            height: Int32(config.height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: sourceAttrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)
        guard createStatus == noErr, let session else {
            throw EncoderError.compressionSessionCreateFailed(createStatus)
        }
        self.compression = session

        try Self.configure(session: session, config: config)

        let prepStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepStatus == noErr else {
            throw EncoderError.prepareFailed(prepStatus)
        }
        self.usingHardware = Self.readUsingHardware(session)
    }

    private static func configure(session: VTCompressionSession, config: Config) throws {
        // Pin the profile where the format has a public constant (4:2:0 → Main), so
        // the client receives a plainly-decodable Main stream. 4:4:4 has none, so
        // it is left for VideoToolbox to derive from the source pixel format.
        if let profile = config.format.profileLevel {
            VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        }
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AverageBitRate,
            value: config.bitrateBitsPerSecond as CFNumber)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: config.fps as CFNumber)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: config.maxKeyFrameInterval as CFNumber)
    }

    private static func readUsingHardware(_ session: VTCompressionSession) -> Bool {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            VTSessionCopyProperty(
                session,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(pointer))
        }
        return status == noErr && (value as? Bool ?? false)
    }

    /// Convert one captured `BGRA` buffer to `v410` and encode it. Synchronous
    /// intake (must be called on the capture serial queue); the compressed output
    /// arrives later via `onEncodedFrame`.
    public func encode(_ source: CVPixelBuffer, pts: CMTime, duration: CMTime) throws {
        let state = Log.signposter.beginInterval("encode")
        defer { Log.signposter.endInterval("encode", state) }

        // BGRA → v410 into a pooled IOSurface buffer.
        var dest: CVPixelBuffer?
        let allocStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, v410Pool, &dest)
        guard allocStatus == kCVReturnSuccess, let dest else {
            throw EncoderError.v410AllocationFailed(allocStatus)
        }
        // Tag the destination so the encoder writes correct color signalling.
        CVBufferSetAttachment(
            dest, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate)
        CVBufferSetAttachment(
            dest, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate)
        CVBufferSetAttachment(
            dest, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2,
            .shouldPropagate)

        let transferStatus = VTPixelTransferSessionTransferImage(transfer, from: source, to: dest)
        guard transferStatus == noErr else {
            throw EncoderError.transferFailed(transferStatus)
        }

        let handler: VTCompressionOutputHandler = { [weak self] status, _, sampleBuffer in
            guard let self, status == noErr, let sampleBuffer else { return }
            self.emit(sampleBuffer)
        }
        let encodeStatus = VTCompressionSessionEncodeFrame(
            compression,
            imageBuffer: dest,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            infoFlagsOut: nil,
            outputHandler: handler)
        guard encodeStatus == noErr else {
            throw EncoderError.encodeFailed(encodeStatus)
        }
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        let byteCount = CMSampleBufferGetTotalSampleSize(sampleBuffer)
        guard byteCount > 0 else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // A frame is a keyframe unless its attachment marks it not-sync.
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
            let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool
        {
            isKeyframe = !notSync
        }

        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            if outputFormatSummary == "unknown" {
                outputFormatSummary = Self.describe(format, chroma: config.format.chromaTag)
            }
            if parameterSetsHVCC == nil {
                parameterSetsHVCC = Self.extractHVCC(from: format)
            }
        }

        let data = extractFrameData ? Self.copyBytes(from: sampleBuffer) : Data()
        onEncodedFrame?(
            EncodedFrame(byteCount: byteCount, pts: pts, isKeyframe: isKeyframe, data: data))
    }

    /// Copy the contiguous encoded bytes out of a sample buffer for the wire.
    private static func copyBytes(from sampleBuffer: CMSampleBuffer) -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return Data() }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return Data() }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(
                block, atOffset: 0, dataLength: length, destination: base)
        }
        return status == noErr ? data : Data()
    }

    /// The `hvcC` configuration record (VPS/SPS/PPS) from a format description.
    private static func extractHVCC(from format: CMFormatDescription) -> Data? {
        guard
            let atoms = CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
                as? [String: Any],
            let hvcC = atoms["hvcC"] as? Data
        else { return nil }
        return hvcC
    }

    /// Flush any buffered frames and tear the sessions down. Idempotent-ish: call
    /// once when capture stops.
    public func finish() {
        VTCompressionSessionCompleteFrames(compression, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(compression)
        VTPixelTransferSessionInvalidate(transfer)
    }

    /// A short human summary of an encoded format description's codec and chroma.
    /// `chroma` is the configured format's tag (the compressed stream does not
    /// re-report its chroma cheaply, so it is passed in from `Config.format`).
    private static func describe(_ format: CMFormatDescription, chroma: String) -> String {
        let codec = fourCC(CMFormatDescriptionGetMediaSubType(format))
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        var chromaLoc = "?"
        if let ext = CMFormatDescriptionGetExtension(
            format, extensionKey: kCMFormatDescriptionExtension_ChromaLocationTopField) as? String
        {
            chromaLoc = ext
        }
        // The subtype tells codec; chroma is the configured source pipeline's.
        return "\(codec) \(dims.width)x\(dims.height) \(chroma) (chromaLoc=\(chromaLoc))"
    }
}
