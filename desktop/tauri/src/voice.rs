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
    SPEAKER.get_or_init(|| {
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
