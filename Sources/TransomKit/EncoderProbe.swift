import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Phase 0 of issue #3 (OQ-4): does this Mac's media engine **hardware-encode**
/// HEVC 4:4:4?
///
/// The project exists to keep syntax-highlighted text crisp; 4:2:0 chroma
/// subsampling fringes exactly that content, so we want 4:4:4 if — and only if —
/// the hardware encoder can do it. Software HEVC 4:4:4 exists but is far too slow
/// for a 60fps live stream, so "software-only" is, for our purposes, a "no".
///
/// This is a **diagnostic**, not the encoder. It answers the question with a real
/// test encode rather than a spec sheet: for each chroma mode it builds a
/// VideoToolbox compression session twice — once *requiring* hardware, once
/// *allowing* software — feeds one IOSurface-backed frame through, and reports
/// what actually happened. `VTCopyVideoEncoderList` and
/// `VTCopySupportedPropertyDictionaryForEncoder` provide the advertised picture;
/// the test encode provides the real one. They can disagree, which is the whole
/// reason to encode.
public enum EncoderProbe {

    // MARK: - Result types

    /// What one create+encode attempt actually did. Every field is observed, none
    /// inferred: `sessionCreated` is the VTCompressionSessionCreate status,
    /// `frameEncoded` means a non-empty sample buffer came back, and
    /// `usingHardware` is VideoToolbox's own read-back, not our guess.
    public struct Attempt: Sendable {
        public let requiredHardware: Bool
        public let sessionCreated: Bool
        public let frameEncoded: Bool
        /// `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder`,
        /// read back after prepare. `nil` if the session never got that far.
        public let usingHardware: Bool?
        public let outputBytes: Int
        /// The `-12908`-style status from the first call that failed, or `noErr`.
        public let status: OSStatus
        /// Human-readable trailing note (e.g. which call failed).
        public let detail: String
    }

    /// One chroma mode (a codec + a source pixel format + an optional profile),
    /// probed under both hardware-required and software-allowed configs.
    public struct ModeResult: Sendable {
        public let label: String
        public let sourceFormat: OSType
        public let profile: String?
        public let requireHardware: Attempt
        public let allowSoftware: Attempt

        public var sourceFormatString: String { fourCC(sourceFormat) }

        /// The verdict for this mode, collapsing both attempts.
        public var verdict: Verdict {
            if requireHardware.frameEncoded { return .hardware }
            if allowSoftware.frameEncoded { return .softwareOnly }
            return .unavailable
        }
    }

    public enum Verdict: String, Sendable {
        case hardware = "HARDWARE"
        case softwareOnly = "SOFTWARE-ONLY"
        case unavailable = "UNAVAILABLE"
    }

    /// One HEVC encoder as advertised by `VTCopyVideoEncoderList`.
    public struct EncoderListing: Sendable {
        public let encoderID: String
        public let displayName: String
        public let isHardware: Bool
    }

    /// A chroma mode to probe: a source pixel format and, where a public
    /// VideoToolbox constant exists, the HEVC profile that matches it.
    struct Mode {
        let label: String
        let sourceFormat: OSType
        let profile: CFString?
        let profileName: String?
    }

    // MARK: - The modes we care about

    /// Ordered coarsest → finest chroma. 4:2:0 is the fallback the issue names;
    /// 4:2:2 is reported because Apple Silicon media engines historically do it in
    /// hardware and it preserves far more chroma than 4:2:0; 4:4:4 is OQ-4 proper.
    /// 4:4:4 has no public HEVC profile constant, so we let VideoToolbox derive
    /// the profile from the source pixel format.
    static var modes: [Mode] {
        [
            Mode(
                label: "HEVC 4:2:0 8-bit",
                sourceFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                profile: kVTProfileLevel_HEVC_Main_AutoLevel,
                profileName: "HEVC_Main_AutoLevel"),
            Mode(
                label: "HEVC 4:2:2 10-bit",
                sourceFormat: kCVPixelFormatType_422YpCbCr10,
                profile: kVTProfileLevel_HEVC_Main42210_AutoLevel,
                profileName: "HEVC_Main42210_AutoLevel"),
            Mode(
                label: "HEVC 4:4:4 8-bit",
                sourceFormat: kCVPixelFormatType_444YpCbCr8,
                profile: nil,
                profileName: nil),
            Mode(
                label: "HEVC 4:4:4 10-bit",
                sourceFormat: kCVPixelFormatType_444YpCbCr10,
                profile: nil,
                profileName: nil),
        ]
    }

    // MARK: - Public entry points

    /// List every HEVC encoder VideoToolbox advertises, with its hardware flag.
    public static func hevcEncoders() -> [EncoderListing] {
        var listRef: CFArray?
        guard VTCopyVideoEncoderList(nil, &listRef) == noErr,
            let entries = listRef as? [[CFString: Any]]
        else { return [] }

        return entries.compactMap { entry in
            guard let codec = entry[kVTVideoEncoderList_CodecType] as? Int,
                CMVideoCodecType(codec) == kCMVideoCodecType_HEVC
            else { return nil }
            let id = entry[kVTVideoEncoderList_EncoderID] as? String ?? "?"
            let name = entry[kVTVideoEncoderList_DisplayName] as? String ?? "?"
            // The key is present-and-true only for hardware encoders.
            let isHW = (entry[kVTVideoEncoderList_IsHardwareAccelerated] as? Bool) ?? false
            return EncoderListing(encoderID: id, displayName: name, isHardware: isHW)
        }
    }

    /// Whether `VTCopySupportedPropertyDictionaryForEncoder` will even hand back a
    /// hardware HEVC encoder for a given frame size, and its id. This is the
    /// "advertised" half; the test encode is the real half.
    public static func supportedHardwareEncoderID(width: Int32 = 1280, height: Int32 = 720)
        -> String?
    {
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        var encoderID: CFString?
        var props: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: width,
            height: height,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec as CFDictionary,
            encoderIDOut: &encoderID,
            supportedPropertiesOut: &props)
        guard status == noErr else { return nil }
        return encoderID as String?
    }

    /// Probe every chroma mode. Runs a real test encode per mode, twice.
    public static func probeAllModes(width: Int = 1280, height: Int = 720) -> [ModeResult] {
        modes.map { mode in
            ModeResult(
                label: mode.label,
                sourceFormat: mode.sourceFormat,
                profile: mode.profileName,
                requireHardware: encodeOneFrame(
                    mode: mode, requireHardware: true, w: width, h: height),
                allowSoftware: encodeOneFrame(
                    mode: mode, requireHardware: false, w: width, h: height))
        }
    }

    // MARK: - The real test encode

    /// A tiny thread-safe sink for the encode output handler. The handler runs
    /// synchronously inside `VTCompressionSessionCompleteFrames`, but VideoToolbox
    /// is free to call it on its own queue, so the lock is real, not decorative —
    /// which is why this is honestly `Sendable` and not `@unchecked`.
    private final class OutputSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _bytes = 0
        private var _frames = 0
        private var _lastStatus: OSStatus = noErr

        func record(status: OSStatus, sample: CMSampleBuffer?) {
            lock.lock()
            defer { lock.unlock() }
            if status != noErr { _lastStatus = status }
            if let sample, let bytes = sample.dataBufferByteCount {
                _bytes += bytes
                _frames += 1
            }
        }

        var bytes: Int { lock.withLock { _bytes } }
        var frames: Int { lock.withLock { _frames } }
        var lastStatus: OSStatus { lock.withLock { _lastStatus } }
    }

    private static func encodeOneFrame(
        mode: Mode, requireHardware: Bool, w: Int, h: Int
    ) -> Attempt {
        var spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        if requireHardware {
            spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = true
        }

        let sourceAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: mode.sourceFormat,
            // Hardware encoders on Apple Silicon require IOSurface-backed input.
            // Omit this and a "hardware" encode silently fails or falls back.
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
            kCVPixelBufferWidthKey: w,
            kCVPixelBufferHeightKey: h,
        ]

        var session: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(w),
            height: Int32(h),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: sourceAttrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,  // nil => use the block-based encode API below
            refcon: nil,
            compressionSessionOut: &session)

        guard createStatus == noErr, let session else {
            return Attempt(
                requiredHardware: requireHardware, sessionCreated: false, frameEncoded: false,
                usingHardware: nil, outputBytes: 0, status: createStatus,
                detail: "VTCompressionSessionCreate failed")
        }
        defer { VTCompressionSessionInvalidate(session) }

        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        if let profile = mode.profile {
            VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        }

        let prepStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        if prepStatus != noErr {
            return Attempt(
                requiredHardware: requireHardware, sessionCreated: true, frameEncoded: false,
                usingHardware: nil, outputBytes: 0, status: prepStatus,
                detail: "PrepareToEncodeFrames failed")
        }

        // VideoToolbox's own read-back of whether hardware is in use. `valueOut`
        // is a raw `void *`, so go through an explicit typed pointer rather than
        // forming a raw pointer to an Optional<AnyObject> implicitly.
        var usingHW: Bool?
        var hwValue: CFTypeRef?
        let copyStatus = withUnsafeMutablePointer(to: &hwValue) { pointer in
            VTSessionCopyProperty(
                session,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(pointer))
        }
        if copyStatus == noErr {
            usingHW = (hwValue as? Bool)
        }

        guard let pixelBuffer = makeFilledPixelBuffer(format: mode.sourceFormat, w: w, h: h) else {
            return Attempt(
                requiredHardware: requireHardware, sessionCreated: true, frameEncoded: false,
                usingHardware: usingHW, outputBytes: 0, status: kCVReturnAllocationFailed,
                detail: "could not allocate a \(fourCC(mode.sourceFormat)) pixel buffer")
        }

        let sink = OutputSink()
        let encodeStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: 0, timescale: 60),
            duration: CMTime(value: 1, timescale: 60),
            frameProperties: nil,
            infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            sink.record(status: status, sample: sampleBuffer)
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        let encoded = sink.frames > 0
        let firstError: OSStatus =
            encodeStatus != noErr ? encodeStatus : sink.lastStatus
        return Attempt(
            requiredHardware: requireHardware,
            sessionCreated: true,
            frameEncoded: encoded,
            usingHardware: usingHW,
            outputBytes: sink.bytes,
            status: firstError,
            detail: encoded ? "encoded \(sink.frames) frame(s)" : "no frame produced")
    }

    /// Allocate an IOSurface-backed pixel buffer of `format` and fill it with a
    /// neutral mid value. Content is irrelevant to a support probe; only that the
    /// format is accepted and encodes.
    private static func makeFilledPixelBuffer(format: OSType, w: Int, h: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
            kCVPixelBufferPixelFormatTypeKey: format,
        ]
        var pb: CVPixelBuffer?
        guard
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, format, attrs as CFDictionary, &pb)
                == kCVReturnSuccess, let pb
        else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        if CVPixelBufferIsPlanar(pb) {
            for plane in 0..<CVPixelBufferGetPlaneCount(pb) {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane) else { continue }
                let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
                let planeHeight = CVPixelBufferGetHeightOfPlane(pb, plane)
                memset(base, 0x80, rowBytes * planeHeight)
            }
        } else if let base = CVPixelBufferGetBaseAddress(pb) {
            memset(base, 0x80, CVPixelBufferGetBytesPerRow(pb) * h)
        }
        return pb
    }
}

extension CMSampleBuffer {
    /// Total encoded byte length of this sample's data buffer, or nil if empty.
    fileprivate var dataBufferByteCount: Int? {
        guard let db = CMSampleBufferGetDataBuffer(self) else { return nil }
        let len = CMBlockBufferGetDataLength(db)
        return len > 0 ? len : nil
    }
}
