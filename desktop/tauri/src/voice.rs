//! Native macOS text-to-speech for the home chat surface.
//!
//! v1 drives the built-in `say(1)` command — the system speech synthesizer, the
//! same voices AVSpeechSynthesizer exposes — from a single background worker
//! thread. `speak` enqueues a line; the worker plays them in order, so a turn's
//! multiple assistant blocks (the chat emits one `:assistant` message per text
//! block, interleaved with tool calls) are spoken back-to-back. `stop_speaking`
//! (barge-in) drops the queue and cuts off the line now playing within one poll
//! tick (~40ms).
//!
//! Subprocess-based rather than AVFoundation FFI on purpose: zero `unsafe`,
//! offline, and the audible result is identical. Swap to AVSpeechSynthesizer
//! later only if we need pause/resume or word-boundary highlighting.

use std::collections::VecDeque;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Condvar, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

/// Shared queue of pending utterances plus the condvar the worker parks on while
/// it is empty, and a generation counter used to signal a barge-in.
struct Speaker {
    queue: Mutex<VecDeque<String>>,
    signal: Condvar,
    /// Bumped by `stop_speaking`. The worker captures this when it starts a line
    /// and aborts that line if the value changes underneath it (barge-in).
    flush_gen: AtomicU64,
}

static SPEAKER: OnceLock<&'static Speaker> = OnceLock::new();

/// Lazily start the speech worker on first use and return the shared handle.
fn speaker() -> &'static Speaker {
    *SPEAKER.get_or_init(|| {
        let speaker: &'static Speaker = Box::leak(Box::new(Speaker {
            queue: Mutex::new(VecDeque::new()),
            signal: Condvar::new(),
            flush_gen: AtomicU64::new(0),
        }));
        thread::spawn(move || worker(speaker));
        speaker
    })
}

/// Background loop: park until there's a line, run `say` to completion, and
/// abort early if a flush (barge-in) lands while it is playing.
fn worker(speaker: &'static Speaker) {
    loop {
        let text = {
            let mut queue = speaker.queue.lock().unwrap();
            while queue.is_empty() {
                queue = speaker.signal.wait(queue).unwrap();
            }
            queue.pop_front().unwrap()
        };

        let my_gen = speaker.flush_gen.load(Ordering::SeqCst);

        let mut child = match spawn_say(&text) {
            Ok(child) => child,
            Err(_) => continue,
        };

        loop {
            // A barge-in bumped the generation — kill the line now playing.
            if speaker.flush_gen.load(Ordering::SeqCst) != my_gen {
                let _ = child.kill();
                let _ = child.wait();
                break;
            }
            match child.try_wait() {
                Ok(Some(_)) => break,
                Ok(None) => thread::sleep(Duration::from_millis(40)),
                Err(_) => break,
            }
        }
    }
}

fn spawn_say(text: &str) -> std::io::Result<Child> {
    // `--` guards against text that begins with `-` being read as a flag.
    Command::new("/usr/bin/say")
        .arg("--")
        .arg(text)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
}

/// Enqueue a line to be spoken aloud. Empty/whitespace input is ignored.
#[tauri::command]
pub fn speak(text: String) {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return;
    }
    let speaker = speaker();
    speaker.queue.lock().unwrap().push_back(trimmed.to_string());
    speaker.signal.notify_one();
}

/// Barge-in: discard everything queued and cut off the line now playing.
#[tauri::command]
pub fn stop_speaking() {
    let speaker = speaker();
    speaker.flush_gen.fetch_add(1, Ordering::SeqCst);
    speaker.queue.lock().unwrap().clear();
}

// ---------------------------------------------------------------------------
// STT build/runtime self-check (voice roadmap Phase 0 — de-risk only)
// ---------------------------------------------------------------------------
//
// This is NOT the recording feature (that's Phase 2). Its only job is to make
// the STT stack *real* to the build: by referencing `cpal` and `whisper_rs`
// here, Cargo actually links whisper.cpp and CoreAudio into the shell, so a
// plain `cargo build` proves the #1 open risk — that static whisper.cpp links
// and survives the toolchain — before any feature code is written. At runtime
// it also confirms a microphone is visible and the bundled model loads, logging
// the result so the on-device check is a glance at the console, not a guess.
//
// Best-effort and fully isolated: it runs on its own thread and never affects
// app startup. `start_recording`/`stop_recording` and their Tauri commands land
// in Phase 2.

/// Probe the STT stack on a background thread (links cpal + whisper.cpp; logs a
/// microphone-present check and a model-load check). Pass the resolved path to
/// the bundled whisper model. No-op off macOS.
#[cfg(target_os = "macos")]
pub fn run_selfcheck(model_path: std::path::PathBuf) {
    thread::spawn(move || {
        use cpal::traits::{DeviceTrait, HostTrait};

        match cpal::default_host().default_input_device() {
            Some(device) => {
                let name = device
                    .description()
                    .map(|d| d.name().to_string())
                    .unwrap_or_else(|_| "<unknown>".to_string());
                eprintln!("[buster-claw][voice] cpal default input device: {name}");
            }
            None => eprintln!(
                "[buster-claw][voice] cpal: no default input device (mic capture will fail)"
            ),
        }

        // The `whisper_rs::WhisperContext` reference below is what forces
        // whisper.cpp to link, independent of whether the model file is present.
        if model_path.exists() {
            match whisper_rs::WhisperContext::new_with_params(
                &model_path,
                whisper_rs::WhisperContextParameters::default(),
            ) {
                Ok(_ctx) => eprintln!(
                    "[buster-claw][voice] whisper model loaded OK: {}",
                    model_path.display()
                ),
                Err(e) => eprintln!(
                    "[buster-claw][voice] whisper model FAILED to load ({}): {e}",
                    model_path.display()
                ),
            }
        } else {
            eprintln!(
                "[buster-claw][voice] whisper model not present at {} \
                 (expected in dev — required for STT in a packaged build; \
                 run scripts/fetch_whisper_model.sh)",
                model_path.display()
            );
        }
    });
}

/// Off macOS the STT crates aren't depended on; nothing to check.
#[cfg(not(target_os = "macos"))]
pub fn run_selfcheck(_model_path: std::path::PathBuf) {}

// ---------------------------------------------------------------------------
// STT: microphone capture + on-device transcription (voice roadmap Phase 2)
// ---------------------------------------------------------------------------
//
// Push-to-talk: the composer's mic button calls `start_recording` on press and
// `stop_recording` on release. We capture mono PCM via cpal, resample to the
// 16 kHz whisper expects, and transcribe with the bundled model — fully offline.
// The text is returned to the webview, which fills the composer (v1 does NOT
// auto-send: the user reviews and presses Enter).

/// Path to the bundled whisper model, set once at startup from `main.rs`
/// (`resolve_voice_model`). Shared with the STT module and the boot self-check.
static MODEL_PATH: std::sync::OnceLock<std::path::PathBuf> = std::sync::OnceLock::new();

/// Record the resolved model path (idempotent; first writer wins).
pub fn set_model_path(path: std::path::PathBuf) {
    let _ = MODEL_PATH.set(path);
}

/// Transcription result handed back to the webview.
#[derive(serde::Serialize)]
pub struct Transcript {
    pub text: String,
}

/// A selectable microphone input device.
#[derive(serde::Serialize)]
pub struct DeviceInfo {
    pub name: String,
    pub is_default: bool,
}

/// Begin capturing the microphone. `device` selects an input by name (from
/// `list_input_devices`); an empty/absent value uses the system default. One
/// recording at a time; a second call while one is active is rejected. Errors
/// (no mic, permission denied) surface to the caller so the UI can show them.
#[cfg(target_os = "macos")]
#[tauri::command]
pub fn start_recording(device: Option<String>) -> Result<(), String> {
    stt::start(device)
}

/// Stop capturing and transcribe what was captured. Returns empty text for a
/// too-short capture rather than an error (an accidental tap shouldn't blow up).
#[cfg(target_os = "macos")]
#[tauri::command]
pub fn stop_recording() -> Result<Transcript, String> {
    stt::stop()
}

/// List the available microphone input devices, flagging the system default.
#[cfg(target_os = "macos")]
#[tauri::command]
pub fn list_input_devices() -> Result<Vec<DeviceInfo>, String> {
    stt::list_devices()
}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
pub fn start_recording(_device: Option<String>) -> Result<(), String> {
    Err("voice input is only available in the macOS desktop app".into())
}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
pub fn stop_recording() -> Result<Transcript, String> {
    Err("voice input is only available in the macOS desktop app".into())
}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
pub fn list_input_devices() -> Result<Vec<DeviceInfo>, String> {
    Err("voice input is only available in the macOS desktop app".into())
}

#[cfg(target_os = "macos")]
mod stt {
    use std::sync::{mpsc, Arc, Mutex, OnceLock};
    use std::thread::JoinHandle;

    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
    use cpal::{FromSample, Sample, SampleFormat, SizedSample};
    use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

    use super::Transcript;

    const TARGET_RATE: u32 = 16_000;
    // Ignore captures shorter than ~0.2s — usually an accidental tap, and too
    // short for whisper to make anything of.
    const MIN_SAMPLES: usize = (TARGET_RATE as usize) / 5;

    /// An in-flight recording: the stop signal, the capture thread (which owns
    /// the cpal stream — `Stream` is `!Send`, so it can never leave that thread),
    /// the shared sample buffer, and the device's capture rate.
    struct Active {
        stop_tx: mpsc::Sender<()>,
        join: JoinHandle<()>,
        samples: Arc<Mutex<Vec<f32>>>,
        sample_rate: u32,
    }

    fn recorder() -> &'static Mutex<Option<Active>> {
        static REC: OnceLock<Mutex<Option<Active>>> = OnceLock::new();
        REC.get_or_init(|| Mutex::new(None))
    }

    // This cpal version exposes the device name via `description().name()`
    // (a `&str`), not the usual `name() -> Result<String>`.
    fn device_name(device: &cpal::Device) -> Option<String> {
        device.description().ok().map(|d| d.name().to_string())
    }

    /// Enumerate input devices, marking the system default.
    pub fn list_devices() -> Result<Vec<super::DeviceInfo>, String> {
        let host = cpal::default_host();
        let default_name = host.default_input_device().and_then(|d| device_name(&d));
        let devices = host
            .input_devices()
            .map_err(|e| format!("could not list input devices: {e}"))?;
        let mut out = Vec::new();
        for d in devices {
            if let Some(name) = device_name(&d) {
                let is_default = default_name.as_deref() == Some(name.as_str());
                out.push(super::DeviceInfo { name, is_default });
            }
        }
        Ok(out)
    }

    fn find_input_device(host: &cpal::Host, name: &str) -> Option<cpal::Device> {
        host.input_devices()
            .ok()?
            .find(|d| device_name(d).as_deref() == Some(name))
    }

    pub fn start(device_name: Option<String>) -> Result<(), String> {
        let mut guard = recorder().lock().unwrap();
        if guard.is_some() {
            return Err("already recording".into());
        }

        let host = cpal::default_host();
        let device = match device_name {
            Some(name) if !name.is_empty() => find_input_device(&host, &name)
                .ok_or_else(|| format!("microphone '{name}' not found"))?,
            _ => host
                .default_input_device()
                .ok_or("no microphone available")?,
        };
        let supported = device
            .default_input_config()
            .map_err(|e| format!("no microphone input config: {e}"))?;
        let sample_rate = supported.sample_rate();
        let channels = supported.channels() as usize;
        let sample_format = supported.sample_format();
        let config = supported.config();

        eprintln!(
            "[buster-claw][voice] start: rate={sample_rate} Hz, channels={channels}, format={sample_format:?}"
        );

        let samples = Arc::new(Mutex::new(Vec::<f32>::new()));
        let samples_for_thread = Arc::clone(&samples);
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let (ready_tx, ready_rx) = mpsc::channel::<Result<(), String>>();

        // Build, start, and eventually drop the stream all on this one thread —
        // cpal's Stream is `!Send`. The thread reports the build result back
        // synchronously, then parks until `stop()` signals; dropping the stream
        // stops capture and flushes the last callback.
        let join = std::thread::spawn(move || {
            let stream =
                match build_stream(&device, config, sample_format, channels, samples_for_thread) {
                    Ok(s) => s,
                    Err(e) => {
                        let _ = ready_tx.send(Err(e));
                        return;
                    }
                };
            if let Err(e) = stream.play() {
                let _ = ready_tx.send(Err(format!("failed to start capture: {e}")));
                return;
            }
            let _ = ready_tx.send(Ok(()));
            let _ = stop_rx.recv();
            drop(stream);
        });

        match ready_rx.recv() {
            Ok(Ok(())) => {}
            Ok(Err(e)) => return Err(e),
            Err(_) => return Err("capture thread exited before starting".into()),
        }

        *guard = Some(Active {
            stop_tx,
            join,
            samples,
            sample_rate,
        });
        Ok(())
    }

    pub fn stop() -> Result<Transcript, String> {
        let active = recorder().lock().unwrap().take().ok_or("not recording")?;
        // Signal the capture thread to drop the stream, then join so every
        // callback write is visible before we read the buffer.
        let _ = active.stop_tx.send(());
        let _ = active.join.join();

        let captured = active.samples.lock().unwrap().clone();
        let n = captured.len();
        let peak = captured.iter().fold(0.0_f32, |m, &s| m.max(s.abs()));
        let rms = if n > 0 {
            (captured.iter().map(|s| s * s).sum::<f32>() / n as f32).sqrt()
        } else {
            0.0
        };
        let dur = n as f32 / active.sample_rate.max(1) as f32;
        let summary = format!(
            "stop: captured {n} samples ({dur:.2}s @ {} Hz), peak={peak:.4}, rms={rms:.4}",
            active.sample_rate
        );
        eprintln!("[buster-claw][voice] {summary}");
        debug_log(&summary);
        // Save exactly what the mic captured (native rate) so we can play it back.
        write_debug_wav("voice-debug-raw.wav", &captured, active.sample_rate);

        let mut audio = resample_to_16k(&captured, active.sample_rate);
        eprintln!(
            "[buster-claw][voice] resampled -> {} samples (16 kHz, {:.2}s)",
            audio.len(),
            audio.len() as f32 / TARGET_RATE as f32
        );

        if audio.len() < MIN_SAMPLES {
            eprintln!(
                "[buster-claw][voice] too short ({} samples) — skipping transcription",
                audio.len()
            );
            debug_log("  -> too short, skipped");
            return Ok(Transcript {
                text: String::new(),
            });
        }

        // Gentle peak normalization: lift a quiet mic toward a healthy level, but
        // leave a near-silent buffer alone so whisper isn't handed amplified noise
        // (which is exactly what makes it hallucinate a stray word or two).
        let apeak = audio.iter().fold(0.0_f32, |m, &s| m.max(s.abs()));
        if apeak > 0.02 && apeak < 0.7 {
            let gain = (0.85 / apeak).min(12.0);
            for s in audio.iter_mut() {
                *s *= gain;
            }
            eprintln!(
                "[buster-claw][voice] normalized: peak {apeak:.4} -> ~{:.4} (gain {gain:.1}x)",
                apeak * gain
            );
        }

        // Save the exact 16 kHz audio handed to whisper — play it back to hear
        // what whisper hears (clean speech vs. distorted/aliased vs. silence).
        write_debug_wav("voice-debug-16k.wav", &audio, TARGET_RATE);

        let transcript = transcribe(&audio)?;
        let tline = format!(
            "  -> transcript ({} chars): {:?}",
            transcript.text.len(),
            transcript.text
        );
        eprintln!("[buster-claw][voice]{tline}");
        debug_log(&tline);
        Ok(transcript)
    }

    /// Append a line to a voice debug log in the app-support dir, so diagnostics
    /// survive even when stderr isn't visible (e.g. a bundled .app, not dev).
    fn debug_log(line: &str) {
        if let Some(path) = debug_path("voice-debug.log") {
            use std::io::Write;
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
            {
                let _ = writeln!(f, "{line}");
            }
        }
    }

    /// Write mono f32 audio as a 16-bit PCM WAV next to the debug log, so the
    /// captured/resampled audio can be played back and inspected by ear.
    fn write_debug_wav(name: &str, audio: &[f32], rate: u32) {
        let Some(path) = debug_path(name) else {
            return;
        };
        let data_len = (audio.len() * 2) as u32;
        let mut bytes: Vec<u8> = Vec::with_capacity(44 + data_len as usize);
        bytes.extend_from_slice(b"RIFF");
        bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
        bytes.extend_from_slice(b"WAVE");
        bytes.extend_from_slice(b"fmt ");
        bytes.extend_from_slice(&16u32.to_le_bytes()); // chunk size
        bytes.extend_from_slice(&1u16.to_le_bytes()); // PCM
        bytes.extend_from_slice(&1u16.to_le_bytes()); // mono
        bytes.extend_from_slice(&rate.to_le_bytes());
        bytes.extend_from_slice(&(rate * 2).to_le_bytes()); // byte rate
        bytes.extend_from_slice(&2u16.to_le_bytes()); // block align
        bytes.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
        bytes.extend_from_slice(b"data");
        bytes.extend_from_slice(&data_len.to_le_bytes());
        for &s in audio {
            let v = (s.clamp(-1.0, 1.0) * 32767.0) as i16;
            bytes.extend_from_slice(&v.to_le_bytes());
        }
        let _ = std::fs::write(path, bytes);
    }

    fn debug_path(name: &str) -> Option<std::path::PathBuf> {
        let home = std::env::var("HOME").ok()?;
        let dir = std::path::PathBuf::from(home).join("Library/Application Support/BusterClaw");
        let _ = std::fs::create_dir_all(&dir);
        Some(dir.join(name))
    }

    fn build_stream(
        device: &cpal::Device,
        config: cpal::StreamConfig,
        format: SampleFormat,
        channels: usize,
        samples: Arc<Mutex<Vec<f32>>>,
    ) -> Result<cpal::Stream, String> {
        let err_fn = |err| eprintln!("[buster-claw][voice] input stream error: {err}");
        let result = match format {
            SampleFormat::F32 => {
                device.build_input_stream(config, capture::<f32>(samples, channels), err_fn, None)
            }
            SampleFormat::I16 => {
                device.build_input_stream(config, capture::<i16>(samples, channels), err_fn, None)
            }
            SampleFormat::U16 => {
                device.build_input_stream(config, capture::<u16>(samples, channels), err_fn, None)
            }
            other => return Err(format!("unsupported sample format: {other:?}")),
        };
        result.map_err(|e| format!("failed to open microphone stream: {e}"))
    }

    /// Per-callback handler: downmix each frame to mono (average channels) and
    /// append as f32 in [-1, 1], the format whisper consumes.
    fn capture<T>(
        samples: Arc<Mutex<Vec<f32>>>,
        channels: usize,
    ) -> impl FnMut(&[T], &cpal::InputCallbackInfo)
    where
        T: Sample + SizedSample,
        f32: FromSample<T>,
    {
        let channels = channels.max(1);
        move |data: &[T], _: &cpal::InputCallbackInfo| {
            let mut buf = samples.lock().unwrap();
            buf.reserve(data.len() / channels);
            for frame in data.chunks(channels) {
                let sum: f32 = frame.iter().map(|s| f32::from_sample(*s)).sum();
                buf.push(sum / channels as f32);
            }
        }
    }

    /// Resample mono f32 to 16 kHz for whisper. Downsampling (the common case —
    /// mics run at 44.1/48 kHz) averages each source window into one output
    /// sample: a cheap box low-pass so frequencies above 8 kHz don't ALIAS back
    /// into the speech band (naive decimation aliases, which garbles whisper).
    /// Upsampling uses linear interpolation.
    fn resample_to_16k(input: &[f32], from_rate: u32) -> Vec<f32> {
        if from_rate == TARGET_RATE || input.is_empty() {
            return input.to_vec();
        }
        let n = input.len();

        if from_rate > TARGET_RATE {
            let ratio = from_rate as f64 / TARGET_RATE as f64; // source samples per output sample
            let out_len = (n as f64 / ratio).round() as usize;
            let mut out = Vec::with_capacity(out_len);
            for i in 0..out_len {
                let start = ((i as f64) * ratio) as usize;
                let mut end = (((i + 1) as f64) * ratio) as usize;
                if end <= start {
                    end = start + 1;
                }
                let end = end.min(n);
                let window = &input[start.min(n)..end];
                let avg = if window.is_empty() {
                    0.0
                } else {
                    window.iter().copied().sum::<f32>() / window.len() as f32
                };
                out.push(avg);
            }
            out
        } else {
            let ratio = TARGET_RATE as f32 / from_rate as f32;
            let out_len = (n as f32 * ratio).round() as usize;
            let mut out = Vec::with_capacity(out_len);
            for i in 0..out_len {
                let src = i as f32 / ratio;
                let idx = src.floor() as usize;
                let frac = src - idx as f32;
                let a = input.get(idx).copied().unwrap_or(0.0);
                let b = input.get(idx + 1).copied().unwrap_or(a);
                out.push(a + (b - a) * frac);
            }
            out
        }
    }

    /// The whisper context is expensive to build (loads the ~142MB model), so
    /// load it once and reuse it; each transcription gets a fresh state.
    fn whisper() -> Result<Arc<WhisperContext>, String> {
        static CTX: OnceLock<Mutex<Option<Arc<WhisperContext>>>> = OnceLock::new();
        let cell = CTX.get_or_init(|| Mutex::new(None));
        let mut guard = cell.lock().unwrap();
        if let Some(ctx) = guard.as_ref() {
            return Ok(Arc::clone(ctx));
        }
        let path = super::MODEL_PATH.get().ok_or("voice model path not set")?;
        if !path.exists() {
            return Err(format!(
                "whisper model not found at {} — run scripts/fetch_whisper_model.sh",
                path.display()
            ));
        }
        let ctx = WhisperContext::new_with_params(path, WhisperContextParameters::default())
            .map_err(|e| format!("failed to load whisper model: {e}"))?;
        let arc = Arc::new(ctx);
        *guard = Some(Arc::clone(&arc));
        Ok(arc)
    }

    fn transcribe(audio: &[f32]) -> Result<Transcript, String> {
        let ctx = whisper()?;
        let mut state = ctx
            .create_state()
            .map_err(|e| format!("whisper state: {e}"))?;

        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        let threads = std::thread::available_parallelism()
            .map(|n| n.get().min(8) as i32)
            .unwrap_or(4);
        params.set_n_threads(threads);
        params.set_language(Some("en"));
        params.set_translate(false);
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);

        state
            .full(params, audio)
            .map_err(|e| format!("transcription failed: {e}"))?;

        let segments = state.full_n_segments();
        let mut text = String::new();
        for i in 0..segments {
            if let Some(seg) = state.get_segment(i) {
                if let Ok(s) = seg.to_str_lossy() {
                    text.push_str(&s);
                }
            }
        }
        Ok(Transcript {
            text: text.trim().to_string(),
        })
    }
}
