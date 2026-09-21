//! HEVC decoding on an MTA worker. Convert the wire's hvcC/length-prefixed
//! samples to Annex B here, without changing the network protocol.
use crate::hevc::HevcConfig;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use windows::core::Interface;
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{
    CoInitializeEx, CoTaskMemFree, CoUninitialize, COINIT_MULTITHREADED,
};

// Three access units is enough to absorb a short decoder hiccup without turning
// the queue into visible remote-desktop latency. If we overflow, we discard the
// dependency chain and ask the host for a fresh keyframe.
const MAX_PENDING_FRAMES: usize = 3;
const MAX_PENDING_BYTES: usize = 16 * 1024 * 1024;

/// A decoded frame in the format produced by the Windows HEVC decoder.
/// Keeping NV12 intact lets D3D11 do the YUV→RGB conversion in the pixel
/// shader instead of expanding every 4K frame to a CPU-owned BGRA buffer.
#[derive(Debug)]
pub struct DecodedFrame {
    pub nv12: Vec<u8>,
    pub stride: usize,
}

#[derive(Default)]
struct PendingInput {
    frames: VecDeque<EncodedFrame>,
    bytes: usize,
    awaiting_keyframe: bool,
    stopped: bool,
}
struct EncodedFrame {
    data: Vec<u8>,
    keyframe: bool,
    pts_micros: u64,
    reset: bool,
}
impl PendingInput {
    /// Queue one compressed access unit. Returns true when the dependency chain
    /// was discarded and the caller should request a new keyframe.
    fn push(&mut self, mut frame: EncodedFrame) -> bool {
        if self.stopped {
            return false;
        }
        let mut request_keyframe = false;
        if self.frames.len() >= MAX_PENDING_FRAMES
            || self.bytes + frame.data.len() > MAX_PENDING_BYTES
        {
            self.frames.clear();
            self.bytes = 0;
            self.awaiting_keyframe = true;
            request_keyframe = true;
        }
        if frame.data.len() > MAX_PENDING_BYTES {
            self.awaiting_keyframe = true;
            return request_keyframe;
        }
        if self.awaiting_keyframe {
            if !frame.keyframe {
                return request_keyframe;
            }
            frame.reset = true;
            self.awaiting_keyframe = false;
        }
        self.bytes += frame.data.len();
        self.frames.push_back(frame);
        request_keyframe
    }
    fn pop(&mut self) -> Option<EncodedFrame> {
        let frame = self.frames.pop_front()?;
        self.bytes -= frame.data.len();
        Some(frame)
    }
}

/// Preserve compressed dependencies in a bounded queue. Only decoded output
/// may safely use a latest-frame mailbox.
pub struct DecoderWorker {
    input: Arc<(Mutex<PendingInput>, Condvar)>,
    output: Arc<Mutex<Option<DecodedFrame>>>,
    error: Arc<Mutex<Option<String>>>,
    keyframe_request: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}
impl DecoderWorker {
    pub fn start(hvcc: Vec<u8>, width: u32, height: u32) -> std::io::Result<Self> {
        let input = Arc::new((
            Mutex::new(PendingInput {
                awaiting_keyframe: true,
                ..Default::default()
            }),
            Condvar::new(),
        ));
        let output = Arc::new(Mutex::new(None));
        let error = Arc::new(Mutex::new(None));
        let worker_input = Arc::clone(&input);
        let worker_output = Arc::clone(&output);
        let worker_error = Arc::clone(&error);
        let keyframe_request = Arc::new(AtomicBool::new(false));
        let worker_keyframe_request = Arc::clone(&keyframe_request);
        let thread = thread::Builder::new()
            .name("transom-decode".into())
            .spawn(move || {
                let result = (|| -> Result<(), String> {
                    let _com = ComApartment::new()?;
                    let mut decoder = Decoder::new(&hvcc, width, height)?;
                    let mut recover = false;
                    let mut decoded = 0;
                    loop {
                        let encoded = {
                            let (lock, ready) = &*worker_input;
                            let mut pending = lock.lock().unwrap_or_else(|e| e.into_inner());
                            while pending.frames.is_empty() && !pending.stopped {
                                pending = ready.wait(pending).unwrap_or_else(|e| e.into_inner());
                            }
                            if pending.stopped {
                                break;
                            }
                            pending.pop().expect("queue checked above")
                        };
                        if recover && !encoded.keyframe {
                            continue;
                        }
                        if encoded.reset || recover {
                            eprintln!(
                                "video: resuming decode at keyframe ({} bytes)",
                                encoded.data.len()
                            );
                            decoder
                                .flush()
                                .map_err(|e| format!("HEVC decoder flush: {e}"))?;
                            recover = false;
                        }
                        match decoder.decode(&encoded.data, encoded.keyframe, encoded.pts_micros) {
                            Ok(Some(frame)) => {
                                decoded += 1;
                                if decoded == 1 {
                                    eprintln!(
                                        "video: first decoded NV12 frame ({} bytes)",
                                        frame.nv12.len()
                                    );
                                }
                                *worker_output.lock().unwrap_or_else(|e| e.into_inner()) =
                                    Some(frame)
                            }
                            Ok(None) => {}
                            Err(e) => {
                                eprintln!("video: {e}");
                                worker_keyframe_request.store(true, Ordering::Release);
                                *worker_error.lock().unwrap_or_else(|e| e.into_inner()) = Some(e);
                                recover = true;
                            }
                        }
                    }
                    Ok(())
                })();
                if let Err(e) = result {
                    eprintln!("video: {e}");
                    *worker_error.lock().unwrap_or_else(|e| e.into_inner()) = Some(e);
                }
                let mut pending = worker_input.0.lock().unwrap_or_else(|e| e.into_inner());
                pending.stopped = true;
                pending.frames.clear();
                pending.bytes = 0;
            })?;
        Ok(Self {
            input,
            output,
            error,
            keyframe_request,
            thread: Some(thread),
        })
    }
    pub fn submit(&self, data: Vec<u8>, keyframe: bool, pts_micros: u64) {
        let (lock, ready) = &*self.input;
        let dropped_chain = lock
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push(EncodedFrame {
                data,
                keyframe,
                pts_micros,
                reset: false,
            });
        if dropped_chain {
            self.keyframe_request.store(true, Ordering::Release);
        }
        ready.notify_one();
    }
    pub fn take_frame(&self) -> Option<DecodedFrame> {
        self.output.lock().unwrap_or_else(|e| e.into_inner()).take()
    }
    pub fn take_error(&self) -> Option<String> {
        self.error.lock().unwrap_or_else(|e| e.into_inner()).take()
    }
    pub fn take_keyframe_request(&self) -> bool {
        self.keyframe_request.swap(false, Ordering::AcqRel)
    }
}
impl Drop for DecoderWorker {
    fn drop(&mut self) {
        let (lock, ready) = &*self.input;
        {
            let mut pending = lock.lock().unwrap_or_else(|e| e.into_inner());
            pending.stopped = true;
            pending.frames.clear();
            ready.notify_one();
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

struct ComApartment;
impl ComApartment {
    fn new() -> Result<Self, String> {
        unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).ok() }
            .map_err(|e| format!("Decoder COM initialization: {e}"))?;
        Ok(Self)
    }
}
impl Drop for ComApartment {
    fn drop(&mut self) {
        unsafe { CoUninitialize() };
    }
}
struct MediaFoundation;
impl MediaFoundation {
    fn new() -> Result<Self, String> {
        unsafe { MFStartup(MF_VERSION, MFSTARTUP_LITE) }
            .map_err(|e| format!("Media Foundation initialization: {e}"))?;
        Ok(Self)
    }
}
impl Drop for MediaFoundation {
    fn drop(&mut self) {
        unsafe {
            let _ = MFShutdown();
        }
    }
}

struct Decoder {
    // Release the transform before shutting down Media Foundation.
    transform: IMFTransform,
    _runtime: MediaFoundation,
    config: HevcConfig,
    width: u32,
    height: u32,
    stride: usize,
    provides_samples: bool,
    out_size: u32,
    out_alignment: u32,
}
impl Decoder {
    fn new(hvcc: &[u8], width: u32, height: u32) -> Result<Self, String> {
        let config = HevcConfig::parse(hvcc)?;
        if config.chroma != 1 || config.bit_depth != 8 {
            return Err(format!("Host sent HEVC chroma {} / {}-bit. Select 4:2:0 8-bit in Mac Video settings and restart sharing.", config.chroma, config.bit_depth));
        }
        let runtime = MediaFoundation::new()?;
        let transforms =
            decoder_candidates().map_err(|e| format!("Find Windows HEVC decoder: {e}"))?;
        if transforms.is_empty() {
            return Err(
                "Windows HEVC decoder is missing. Install HEVC Video Extensions, then reconnect."
                    .into(),
            );
        }
        let mut failures = Vec::new();
        for candidate in transforms {
            let configured = unsafe {
                (|| -> Result<IMFTransform, String> {
                    let transform: IMFTransform = candidate
                        .ActivateObject()
                        .map_err(|e| format!("Activate HEVC decoder: {e}"))?;
                    if let Ok(attrs) = transform.GetAttributes() {
                        let _ = attrs.SetUINT32(&MF_LOW_LATENCY, 1);
                    }
                    if let Ok(codec) = transform.cast::<ICodecAPI>() {
                        let _ = codec.SetValue(&CODECAPI_AVLowLatencyMode, &true.into());
                    }
                    let input = MFCreateMediaType().map_err(|e| e.to_string())?;
                    input
                        .SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)
                        .map_err(|e| e.to_string())?;
                    input
                        .SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_HEVC)
                        .map_err(|e| e.to_string())?;
                    input
                        .SetUINT64(&MF_MT_FRAME_SIZE, pack_size(width, height))
                        .map_err(|e| e.to_string())?;
                    input
                        .SetUINT32(&MF_MT_MPEG2_PROFILE, config.profile)
                        .map_err(|e| e.to_string())?;
                    input
                        .SetBlob(&MF_MT_MPEG_SEQUENCE_HEADER, &config.parameter_sets)
                        .map_err(|e| e.to_string())?;
                    transform
                        .SetInputType(0, &input, 0)
                        .map_err(|e| format!("Set HEVC input type: {e}"))?;
                    Ok(transform)
                })()
            };
            match configured {
                Ok(transform) => {
                    let mut decoder = Self {
                        transform,
                        _runtime: runtime,
                        config,
                        width,
                        height,
                        stride: width as usize,
                        provides_samples: false,
                        out_size: 0,
                        out_alignment: 0,
                    };
                    unsafe {
                        decoder
                            .reset_output_type()
                            .map_err(|e| format!("Set HEVC output type: {e}"))?;
                        decoder
                            .transform
                            .ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)
                            .map_err(|e| e.to_string())?;
                        decoder
                            .transform
                            .ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)
                            .map_err(|e| e.to_string())?;
                    }
                    eprintln!(
                        "video: HEVC decoder ready, {}x{}, Main 4:2:0 8-bit, Annex B",
                        width, height
                    );
                    return Ok(decoder);
                }
                Err(e) => failures.push(e),
            }
        }
        Err(failures.join("; "))
    }
    fn decode(
        &mut self,
        au: &[u8],
        keyframe: bool,
        pts_micros: u64,
    ) -> Result<Option<DecodedFrame>, String> {
        let bytes = self.config.annex_b(au, keyframe)?;
        unsafe {
            let sample = make_input_sample(&bytes, keyframe, pts_micros)
                .map_err(|e| format!("Create HEVC input sample: {e}"))?;
            let mut latest = None;
            match self.transform.ProcessInput(0, &sample, 0) {
                Ok(()) => {}
                Err(e) if e.code() == MF_E_NOTACCEPTING => {
                    latest = self.drain()?;
                    // NOTACCEPTING did not consume this input. Retry the same
                    // sample after draining to preserve compressed dependencies.
                    self.transform
                        .ProcessInput(0, &sample, 0)
                        .map_err(|e| format!("Retry HEVC input: {e}"))?;
                }
                Err(e) => return Err(format!("Decode HEVC input: {e}")),
            }
            Ok(self.drain()?.or(latest))
        }
    }
    fn flush(&mut self) -> windows::core::Result<()> {
        unsafe {
            self.transform
                .ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0)?;
            self.transform
                .ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)?;
        }
        Ok(())
    }
    unsafe fn drain(&mut self) -> Result<Option<DecodedFrame>, String> {
        let mut latest = None;
        // Bound repeated STREAM_CHANGE responses without progress.
        for _ in 0..64 {
            let out_sample = if self.provides_samples {
                None
            } else {
                let sample = MFCreateSample().map_err(|e| e.to_string())?;
                let buffer = MFCreateAlignedMemoryBuffer(self.out_size.max(1), self.out_alignment)
                    .map_err(|e| e.to_string())?;
                sample.AddBuffer(&buffer).map_err(|e| e.to_string())?;
                Some(sample)
            };
            let mut buffers = [MFT_OUTPUT_DATA_BUFFER {
                dwStreamID: 0,
                pSample: std::mem::ManuallyDrop::new(out_sample),
                dwStatus: 0,
                pEvents: std::mem::ManuallyDrop::new(None),
            }];
            let mut status = 0;
            let result = self.transform.ProcessOutput(0, &mut buffers, &mut status);
            // These COM outputs are owned on every path, including errors.
            let sample = std::mem::ManuallyDrop::take(&mut buffers[0].pSample);
            drop(std::mem::ManuallyDrop::take(&mut buffers[0].pEvents));
            match result {
                Ok(()) => {
                    if let Some(sample) = sample {
                        latest = Some(self.sample_to_nv12(&sample)?);
                    }
                }
                Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(latest),
                Err(e) if e.code() == MF_E_TRANSFORM_STREAM_CHANGE => {
                    self.reset_output_type()
                        .map_err(|e| format!("HEVC output format changed: {e}"))?;
                }
                Err(e) => return Err(format!("Decode HEVC output: {e}")),
            }
        }
        Err("HEVC decoder made no progress while draining output".into())
    }
    unsafe fn reset_output_type(&mut self) -> windows::core::Result<()> {
        let mut index = 0;
        loop {
            let output = self.transform.GetOutputAvailableType(0, index)?;
            index += 1;
            if output.GetGUID(&MF_MT_SUBTYPE)? != MFVideoFormat_NV12 {
                continue;
            }
            let size = output
                .GetUINT64(&MF_MT_FRAME_SIZE)
                .unwrap_or(pack_size(self.width, self.height));
            if size != pack_size(self.width, self.height) {
                return Err(windows::core::Error::new(
                    MF_E_INVALIDMEDIATYPE,
                    "Decoded size differs from host display; refusing to scale",
                ));
            }
            output.SetUINT64(&MF_MT_FRAME_SIZE, size)?;
            self.transform.SetOutputType(0, &output, 0)?;
            self.stride = output
                .GetUINT32(&MF_MT_DEFAULT_STRIDE)
                .unwrap_or(self.width) as usize;
            let info = self.transform.GetOutputStreamInfo(0)?;
            self.provides_samples = info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 as u32 != 0;
            self.out_size = info.cbSize;
            self.out_alignment = info.cbAlignment.saturating_sub(1);
            return Ok(());
        }
    }
    unsafe fn sample_to_nv12(&self, sample: &IMFSample) -> Result<DecodedFrame, String> {
        let buffer = sample
            .ConvertToContiguousBuffer()
            .map_err(|e| e.to_string())?;
        if let Ok(two_d) = buffer.cast::<IMF2DBuffer>() {
            let mut packed =
                vec![0; two_d.GetContiguousLength().map_err(|e| e.to_string())? as usize];
            two_d
                .ContiguousCopyTo(&mut packed)
                .map_err(|e| e.to_string())?;
            return validate_nv12(packed, self.width, self.height, self.stride);
        }
        let mut ptr = std::ptr::null_mut();
        let mut len = 0;
        buffer
            .Lock(&mut ptr, None, Some(&mut len))
            .map_err(|e| e.to_string())?;
        let bytes = std::slice::from_raw_parts(ptr, len as usize).to_vec();
        let unlock = buffer.Unlock();
        unlock.map_err(|e| e.to_string())?;
        validate_nv12(bytes, self.width, self.height, self.stride)
    }
}
impl Drop for Decoder {
    fn drop(&mut self) {
        unsafe {
            let _ = self
                .transform
                .ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
        }
    }
}
fn decoder_candidates() -> windows::core::Result<Vec<IMFActivate>> {
    unsafe {
        let input = MFT_REGISTER_TYPE_INFO {
            guidMajorType: MFMediaType_Video,
            guidSubtype: MFVideoFormat_HEVC,
        };
        let mut array = std::ptr::null_mut();
        let mut count = 0;
        MFTEnumEx(
            MFT_CATEGORY_VIDEO_DECODER,
            MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER,
            Some(&input),
            None,
            &mut array,
            &mut count,
        )?;
        let mut candidates = Vec::new();
        if !array.is_null() {
            for entry in std::slice::from_raw_parts_mut(array, count as usize) {
                if let Some(activate) = entry.take() {
                    candidates.push(activate);
                }
            }
            CoTaskMemFree(Some(array.cast()));
        }
        Ok(candidates)
    }
}
unsafe fn make_input_sample(
    bytes: &[u8],
    keyframe: bool,
    pts_micros: u64,
) -> windows::core::Result<IMFSample> {
    let sample = MFCreateSample()?;
    let buffer = MFCreateMemoryBuffer(bytes.len() as u32)?;
    let mut ptr = std::ptr::null_mut();
    buffer.Lock(&mut ptr, None, None)?;
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, bytes.len());
    buffer.Unlock()?;
    buffer.SetCurrentLength(bytes.len() as u32)?;
    sample.AddBuffer(&buffer)?;
    sample.SetSampleTime(pts_micros.saturating_mul(10).min(i64::MAX as u64) as i64)?;
    sample.SetUINT32(&MFSampleExtension_CleanPoint, u32::from(keyframe))?;
    Ok(sample)
}
fn pack_size(width: u32, height: u32) -> u64 {
    ((width as u64) << 32) | height as u64
}

fn validate_nv12(
    nv12: Vec<u8>,
    width: u32,
    height: u32,
    stride: usize,
) -> Result<DecodedFrame, String> {
    let needed = stride
        .checked_mul(height as usize)
        .and_then(|y| y.checked_add(stride.checked_mul(height as usize / 2)?))
        .ok_or_else(|| "Invalid NV12 output dimensions".to_string())?;
    if width == 0 || height == 0 || width % 2 != 0 || height % 2 != 0 || stride < width as usize {
        return Err("Invalid NV12 output dimensions or stride".into());
    }
    if nv12.len() < needed {
        return Err("Invalid NV12 output buffer size".into());
    }
    Ok(DecodedFrame { nv12, stride })
}

/// BT.709 limited-range NV12, respecting padded rows without resizing.
#[cfg(test)]
fn nv12_to_bgra(nv12: &[u8], width: u32, height: u32, stride: usize) -> Option<Vec<u8>> {
    let w = width as usize;
    let h = height as usize;
    if w == 0 || h == 0 || w % 2 != 0 || h % 2 != 0 || stride < w {
        return None;
    }
    let y_size = stride.checked_mul(h)?;
    let needed = y_size.checked_add(stride.checked_mul(h / 2)?)?;
    if nv12.len() < needed {
        return None;
    }
    let (y_plane, uv_plane) = nv12.split_at(y_size);
    let mut bgra = vec![0; w.checked_mul(h)?.checked_mul(4)?];
    for row in 0..h {
        for col in 0..w {
            let y = i32::from(y_plane[row * stride + col]) - 16;
            let uv = (row / 2) * stride + (col / 2) * 2;
            let u = i32::from(uv_plane[uv]) - 128;
            let v = i32::from(uv_plane[uv + 1]) - 128;
            let o = (row * w + col) * 4;
            bgra[o] = ((298 * y + 541 * u + 128) >> 8).clamp(0, 255) as u8;
            bgra[o + 1] = ((298 * y - 55 * u - 136 * v + 128) >> 8).clamp(0, 255) as u8;
            bgra[o + 2] = ((298 * y + 459 * v + 128) >> 8).clamp(0, 255) as u8;
            bgra[o + 3] = 255;
        }
    }
    Some(bgra)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn worker_reports_invalid_config_without_waiting_for_video_frames() {
        let worker = DecoderWorker::start(vec![1, 2], 128, 96).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        loop {
            if let Some(error) = worker.take_error() {
                assert!(error.contains("HEVC configuration"), "{error}");
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "worker failed silently"
            );
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }
    #[test]
    fn nv12_handles_padding_and_rejects_short_or_odd_frames() {
        let packed = [16, 235, 16, 235, 128, 128];
        let padded = [16, 235, 99, 99, 16, 235, 99, 99, 128, 128, 99, 99];
        let expected = vec![
            0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255,
        ];
        assert_eq!(nv12_to_bgra(&packed, 2, 2, 2), Some(expected.clone()));
        assert_eq!(nv12_to_bgra(&padded, 2, 2, 4), Some(expected));
        assert!(nv12_to_bgra(&packed[..5], 2, 2, 2).is_none());
        assert!(nv12_to_bgra(&packed, 1, 2, 2).is_none());
    }
    fn encoded(n: u64, keyframe: bool) -> EncodedFrame {
        EncodedFrame {
            data: vec![n as u8],
            keyframe,
            pts_micros: n,
            reset: false,
        }
    }
    #[test]
    fn compressed_frames_keep_order_and_recover_at_keyframe_after_overflow() {
        let mut queue = PendingInput {
            awaiting_keyframe: true,
            ..Default::default()
        };
        queue.push(encoded(0, false));
        assert!(queue.pop().is_none());
        queue.push(encoded(1, true));
        queue.push(encoded(2, false));
        assert!(queue.pop().unwrap().reset);
        assert_eq!(queue.pop().unwrap().pts_micros, 2);
        for n in 0..=MAX_PENDING_FRAMES {
            queue.push(encoded(n as u64, false));
        }
        assert!(queue.pop().is_none());
        queue.push(encoded(10, false));
        assert!(queue.pop().is_none());
        queue.push(encoded(11, true));
        assert!(queue.pop().unwrap().reset);
    }
    #[test]
    #[ignore = "Requires an installed Windows HEVC decoder; run on target PC"]
    fn decodes_hevc_fixture_on_windows() {
        use crate::net::FramedReceiver;
        use crate::wire::VideoMessage;
        let _com = ComApartment::new().unwrap();
        let data = include_bytes!("../../tests/fixtures/hevc-main.wire");
        let mut wire = FramedReceiver::new(&data[..]);
        let VideoMessage::Config { hvcc } =
            VideoMessage::decode(&wire.recv().unwrap().unwrap()).unwrap()
        else {
            panic!("config expected")
        };
        let mut decoder = Decoder::new(&hvcc, 128, 96).unwrap();
        let mut count = 0;
        while let Some(payload) = wire.recv().unwrap() {
            let VideoMessage::Frame {
                data,
                keyframe,
                pts_micros,
                ..
            } = VideoMessage::decode(&payload).unwrap()
            else {
                panic!("frame expected")
            };
            if let Some(bgra) = decoder.decode(&data, keyframe, pts_micros).unwrap() {
                assert_eq!(bgra.len(), 128 * 96 * 4);
                assert!(
                    bgra.chunks_exact(4).any(|p| p[0].abs_diff(p[2]) > 100),
                    "test colors must survive decode"
                );
                count += 1;
            }
        }
        eprintln!("Media Foundation decoded {count} real HEVC frames at 128x96");
        assert!(count >= 8, "expected most frames, got {count}");
    }
}
