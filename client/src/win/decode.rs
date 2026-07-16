//! HEVC decode via Media Foundation.
//!
//! The host sends `hvcC` parameter sets once (protocol.md §6), then a stream of
//! HEVC 4:4:4 10-bit access units. This drives the system H.265 decoder MFT: feed
//! it the sequence header plus each access unit, pull decoded frames back, and
//! convert to the BGRA the renderer's shared texture wants.
//!
//! **Verification honesty (I-7):** unlike the wire core, this path cannot be
//! exercised from a Mac — there is no Media Foundation and no HEVC hardware here.
//! It is written to the documented MF contract and compiled against the Windows
//! toolchain, but its runtime bring-up (does the system MFT accept 4:4:4 10-bit;
//! does STREAM_CHANGE renegotiate cleanly) must happen on the real Windows box.
//! Every fallible step degrades to "no frame this call", so a decode problem
//! shows the placeholder texture rather than crashing the window manager. The
//! transform and the current CPU color conversion live on `DecoderWorker`, never
//! on the Win32 message-pump thread.

use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};

use windows::core::GUID;
use windows::Win32::Media::MediaFoundation::{
    IMFMediaType, IMFSample, IMFTransform, MFCreateMediaType, MFCreateMemoryBuffer,
    MFCreateSample, MFStartup, MFMediaType_Video, MFVideoFormat_HEVC, MFVideoFormat_NV12,
    MFSTARTUP_LITE, MFT_MESSAGE_COMMAND_FLUSH, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING,
    MFT_MESSAGE_NOTIFY_END_OF_STREAM, MFT_MESSAGE_NOTIFY_START_OF_STREAM,
    MFT_OUTPUT_DATA_BUFFER, MFT_OUTPUT_STREAM_INFO, MFT_OUTPUT_STREAM_PROVIDES_SAMPLES,
    MF_MT_FRAME_SIZE, MF_MT_MAJOR_TYPE, MF_MT_MPEG_SEQUENCE_HEADER, MF_MT_SUBTYPE, MF_VERSION,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER,
    COINIT_MULTITHREADED,
};

/// `CLSID_CMSH265DecoderMFT` — the in-box Microsoft HEVC decoder.
const CLSID_H265_DECODER: GUID = GUID::from_u128(0x420a_51a3_d605_430c_a02c_6ef0_2f3e_0b03);

/// The MF error returned when the decoder has consumed all input and needs more
/// before it can produce a frame. (`MF_E_TRANSFORM_NEED_MORE_INPUT`.)
const MF_E_TRANSFORM_NEED_MORE_INPUT: windows::core::HRESULT =
    windows::core::HRESULT(0xC00D_6D72u32 as i32);
/// The output format changed and must be renegotiated. (`MF_E_TRANSFORM_STREAM_CHANGE`.)
const MF_E_TRANSFORM_STREAM_CHANGE: windows::core::HRESULT =
    windows::core::HRESULT(0xC00D_6D61u32 as i32);
/// The transform can't accept more input until output is drained.
/// (`MF_E_NOTACCEPTING`.)
const MF_E_NOTACCEPTING: windows::core::HRESULT = windows::core::HRESULT(0xC00D_36B3u32 as i32);

struct PendingInput {
    frame: Option<EncodedFrame>,
    dropped_dependency: bool,
    stopped: bool,
}

struct EncodedFrame {
    data: Vec<u8>,
    keyframe: bool,
}

/// Keeps Media Foundation decode and the full-frame NV12→BGRA conversion off the
/// Win32 UI thread. Both mailboxes contain only the newest frame: if either side
/// falls behind, stale video is replaced instead of accumulating latency or
/// unbounded memory.
pub struct DecoderWorker {
    input: Arc<(Mutex<PendingInput>, Condvar)>,
    output: Arc<Mutex<Option<Vec<u8>>>>,
    thread: Option<JoinHandle<()>>,
}

impl DecoderWorker {
    pub fn start(hvcc: Vec<u8>, width: u32, height: u32) -> std::io::Result<DecoderWorker> {
        let input = Arc::new((
            Mutex::new(PendingInput {
                frame: None,
                dropped_dependency: false,
                stopped: false,
            }),
            Condvar::new(),
        ));
        let output = Arc::new(Mutex::new(None));
        let worker_input = Arc::clone(&input);
        let worker_output = Arc::clone(&output);

        let thread = thread::Builder::new()
            .name("transom-decode".into())
            .spawn(move || {
                if let Err(e) = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).ok() } {
                    eprintln!("decoder worker COM init failed: {e}");
                    return;
                }

                let mut decoder = match Decoder::new(&hvcc, width, height) {
                    Ok(decoder) => decoder,
                    Err(e) => {
                        eprintln!("decoder init failed: {e}");
                        unsafe { CoUninitialize() };
                        return;
                    }
                };

                let mut waiting_for_keyframe = false;
                loop {
                    let (encoded, dropped_dependency) = {
                        let (lock, ready) = &*worker_input;
                        let mut pending = lock.lock().unwrap_or_else(|e| e.into_inner());
                        while pending.frame.is_none() && !pending.stopped {
                            pending = ready.wait(pending).unwrap_or_else(|e| e.into_inner());
                        }
                        if pending.stopped {
                            break;
                        }
                        let encoded = pending.frame.take().expect("frame checked above");
                        let dropped_dependency = pending.dropped_dependency;
                        pending.dropped_dependency = false;
                        (encoded, dropped_dependency)
                    };

                    // HEVC frames depend on earlier frames. If the latest-frame
                    // mailbox replaced a queued access unit, skip deltas until a
                    // keyframe arrives, flush the MFT, and restart from that clean
                    // random-access point instead of feeding a broken reference
                    // chain to the decoder.
                    waiting_for_keyframe |= dropped_dependency;
                    if waiting_for_keyframe {
                        if !encoded.keyframe {
                            continue;
                        }
                        if decoder.flush().is_err() {
                            continue;
                        }
                        waiting_for_keyframe = false;
                    }

                    if let Some(frame) = decoder.decode(&encoded.data) {
                        *worker_output.lock().unwrap_or_else(|e| e.into_inner()) = Some(frame);
                    }
                }

                // Release the MFT while this thread's COM apartment still exists.
                drop(decoder);
                unsafe { CoUninitialize() };
            })?;

        Ok(DecoderWorker {
            input,
            output,
            thread: Some(thread),
        })
    }

    /// Replace any not-yet-decoded access unit with the newest one.
    pub fn submit(&self, access_unit: Vec<u8>, keyframe: bool) {
        let (lock, ready) = &*self.input;
        let mut pending = lock.lock().unwrap_or_else(|e| e.into_inner());
        if pending.stopped {
            return;
        }
        if pending.frame.is_some() {
            pending.dropped_dependency = true;
        }
        pending.frame = Some(EncodedFrame {
            data: access_unit,
            keyframe,
        });
        ready.notify_one();
    }

    /// Take the newest completed BGRA frame without blocking the UI thread.
    pub fn take_frame(&self) -> Option<Vec<u8>> {
        self.output
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .take()
    }
}

impl Drop for DecoderWorker {
    fn drop(&mut self) {
        let (lock, ready) = &*self.input;
        {
            let mut pending = lock.lock().unwrap_or_else(|e| e.into_inner());
            pending.stopped = true;
            pending.frame = None;
            ready.notify_one();
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

struct Decoder {
    transform: IMFTransform,
    width: u32,
    height: u32,
    provides_samples: bool,
    out_size: usize,
}

impl Decoder {
    fn new(hvcc: &[u8], width: u32, height: u32) -> windows::core::Result<Decoder> {
        unsafe {
            // Idempotent across decoders; the process never calls MFShutdown and
            // relies on teardown at exit.
            MFStartup(MF_VERSION, MFSTARTUP_LITE)?;

            let transform: IMFTransform =
                CoCreateInstance(&CLSID_H265_DECODER, None, CLSCTX_INPROC_SERVER)?;

            // Input type: HEVC at the VDS size, with the sequence header from hvcC.
            let input: IMFMediaType = MFCreateMediaType()?;
            input.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            input.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_HEVC)?;
            input.SetUINT64(&MF_MT_FRAME_SIZE, pack_size(width, height))?;
            if !hvcc.is_empty() {
                input.SetBlob(&MF_MT_MPEG_SEQUENCE_HEADER, hvcc)?;
            }
            transform.SetInputType(0, &input, 0)?;

            // Output type: NV12 at the same size.
            let output: IMFMediaType = MFCreateMediaType()?;
            output.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            output.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12)?;
            output.SetUINT64(&MF_MT_FRAME_SIZE, pack_size(width, height))?;
            transform.SetOutputType(0, &output, 0)?;

            transform.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)?;
            transform.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)?;

            let info: MFT_OUTPUT_STREAM_INFO = transform.GetOutputStreamInfo(0)?;
            let provides_samples =
                (info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 as u32) != 0;
            let out_size = info.cbSize as usize;

            Ok(Decoder {
                transform,
                width,
                height,
                provides_samples,
                out_size,
            })
        }
    }

    /// Feed one access unit and return a decoded BGRA frame if one came out.
    /// Returns `None` when the decoder needs more input, or on any recoverable
    /// error (the caller keeps the last frame on screen).
    pub fn decode(&mut self, au: &[u8]) -> Option<Vec<u8>> {
        unsafe {
            let sample = self.make_input_sample(au).ok()?;
            match self.transform.ProcessInput(0, &sample, 0) {
                Ok(()) => {}
                Err(e) if e.code() == MF_E_NOTACCEPTING => {
                    // Need to drain output before it will take more input.
                }
                Err(_) => return None,
            }
            self.drain_one_frame()
        }
    }

    fn flush(&mut self) -> windows::core::Result<()> {
        unsafe {
            self.transform.ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0)?;
            self.transform
                .ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)?;
        }
        Ok(())
    }

    unsafe fn make_input_sample(&self, au: &[u8]) -> windows::core::Result<IMFSample> {
        let sample = MFCreateSample()?;
        let buffer = MFCreateMemoryBuffer(au.len() as u32)?;
        let mut ptr = std::ptr::null_mut();
        buffer.Lock(&mut ptr, None, None)?;
        std::ptr::copy_nonoverlapping(au.as_ptr(), ptr, au.len());
        buffer.SetCurrentLength(au.len() as u32)?;
        buffer.Unlock()?;
        sample.AddBuffer(&buffer)?;
        Ok(sample)
    }

    /// Pull at most one decoded frame out of the transform.
    unsafe fn drain_one_frame(&mut self) -> Option<Vec<u8>> {
        loop {
            // If the MFT doesn't allocate its own output samples, supply one of the
            // reported size; otherwise hand it an empty slot to fill.
            let out_sample: Option<IMFSample> = if self.provides_samples {
                None
            } else {
                let s = MFCreateSample().ok()?;
                let b = MFCreateMemoryBuffer(self.out_size.max(1) as u32).ok()?;
                s.AddBuffer(&b).ok()?;
                Some(s)
            };

            let mut buffers = [MFT_OUTPUT_DATA_BUFFER {
                dwStreamID: 0,
                pSample: std::mem::ManuallyDrop::new(out_sample),
                dwStatus: 0,
                pEvents: std::mem::ManuallyDrop::new(None),
            }];
            let mut status = 0u32;

            match self.transform.ProcessOutput(0, &mut buffers, &mut status) {
                Ok(()) => {
                    let sample = std::mem::ManuallyDrop::take(&mut buffers[0].pSample);
                    let frame = sample.and_then(|s| self.sample_to_bgra(&s));
                    return frame;
                }
                Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return None,
                Err(e) if e.code() == MF_E_TRANSFORM_STREAM_CHANGE => {
                    // Renegotiate NV12 output at the current size and retry once.
                    if self.reset_output_type().is_err() {
                        return None;
                    }
                    continue;
                }
                Err(_) => return None,
            }
        }
    }

    unsafe fn reset_output_type(&mut self) -> windows::core::Result<()> {
        let output: IMFMediaType = MFCreateMediaType()?;
        output.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
        output.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12)?;
        output.SetUINT64(&MF_MT_FRAME_SIZE, pack_size(self.width, self.height))?;
        self.transform.SetOutputType(0, &output, 0)?;
        let info = self.transform.GetOutputStreamInfo(0)?;
        self.out_size = info.cbSize as usize;
        Ok(())
    }

    /// Lock the decoded NV12 sample's buffer and convert to BGRA.
    unsafe fn sample_to_bgra(&self, sample: &IMFSample) -> Option<Vec<u8>> {
        let buffer = sample.ConvertToContiguousBuffer().ok()?;
        let mut ptr = std::ptr::null_mut();
        let mut len = 0u32;
        buffer.Lock(&mut ptr, None, Some(&mut len)).ok()?;
        let data = std::slice::from_raw_parts(ptr, len as usize);
        let bgra = nv12_to_bgra(data, self.width, self.height);
        let _ = buffer.Unlock();
        bgra
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

/// Pack a width/height into the `u64` MF uses for `MF_MT_FRAME_SIZE`.
fn pack_size(width: u32, height: u32) -> u64 {
    ((width as u64) << 32) | (height as u64)
}

/// Convert an NV12 buffer (`w*h` Y plane, then interleaved `w*h/2` UV) to BGRA.
/// BT.709 limited-range, the usual choice for HD video. Returns `None` if the
/// buffer is too small for the claimed dimensions.
fn nv12_to_bgra(nv12: &[u8], width: u32, height: u32) -> Option<Vec<u8>> {
    let w = width as usize;
    let h = height as usize;
    let y_size = w * h;
    let needed = y_size + (w * h / 2);
    if nv12.len() < needed {
        return None;
    }
    let (y_plane, uv_plane) = nv12.split_at(y_size);

    let mut bgra = vec![0u8; w * h * 4];
    for row in 0..h {
        for col in 0..w {
            let yv = y_plane[row * w + col] as f32;
            // UV is subsampled 2x2; each pair covers a 2x2 block.
            let uv_index = (row / 2) * w + (col / 2) * 2;
            let u = uv_plane[uv_index] as f32 - 128.0;
            let v = uv_plane[uv_index + 1] as f32 - 128.0;
            let c = yv - 16.0;
            let r = (1.164 * c + 1.793 * v).clamp(0.0, 255.0);
            let g = (1.164 * c - 0.213 * u - 0.533 * v).clamp(0.0, 255.0);
            let b = (1.164 * c + 2.112 * u).clamp(0.0, 255.0);
            let o = (row * w + col) * 4;
            bgra[o] = b as u8;
            bgra[o + 1] = g as u8;
            bgra[o + 2] = r as u8;
            bgra[o + 3] = 255;
        }
    }
    Some(bgra)
}
