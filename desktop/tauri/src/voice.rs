//! Native macOS text-to-speech for the home chat surface.
//!
//! Drives the built-in `say(1)` command — the system speech synthesizer, the
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
//!
//! ## Why the voice travels with the line, not with the worker
//!
//! v1 ran bare `say --  <text>`, which means the app spoke in whatever voice the
//! Mac's System Settings happened to be set to — the app had no voice of its
//! own, it borrowed the OS's. The voice and rate now ride on each queued
//! utterance rather than living in worker state, so a settings change takes
//! effect on the next line without a restart, and an audition can preview a
//! voice the operator has not committed to yet while a reply is still queued in
//! another.
//!
//! Both are optional at every layer: `None` means "whatever the system is set
//! to", which is exactly v1's behaviour and the honest default for an app that
//! has not been told what to sound like.

use std::collections::VecDeque;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Condvar, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

/// `say -r` is words per minute. Its own default sits near 175; the bounds here
/// are the range that stays intelligible — far below 100 the pauses between
/// words read as a fault, and past 400 consonants smear together.
const RATE_MIN: u32 = 100;
const RATE_MAX: u32 = 400;

/// One queued line, carrying the voice it should be spoken in.
struct Utterance {
    text: String,
    voice: Option<String>,
    rate: Option<u32>,
}

/// A voice `say` can use, as reported by the system.
#[derive(serde::Serialize)]
pub struct Voice {
    /// The exact string to hand back as `speak`'s `voice` argument.
    name: String,
    /// BCP-47-ish locale, e.g. `en_US`. Lets the UI group and filter.
    locale: String,
    /// The sample sentence `say` ships for the voice, e.g. "Hello! My name is
    /// Albert." Useful as audition text because it is in the voice's language.
    sample: String,
}

/// Shared queue of pending utterances plus the condvar the worker parks on while
/// it is empty, and a generation counter used to signal a barge-in.
struct Speaker {
    queue: Mutex<VecDeque<Utterance>>,
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
        let utterance = {
            let mut queue = speaker.queue.lock().unwrap();
            while queue.is_empty() {
                queue = speaker.signal.wait(queue).unwrap();
            }
            queue.pop_front().unwrap()
        };

        let my_gen = speaker.flush_gen.load(Ordering::SeqCst);

        let mut child = match spawn_say(&utterance) {
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

fn spawn_say(utterance: &Utterance) -> std::io::Result<Child> {
    let mut command = Command::new("/usr/bin/say");

    // Flags first: `say` reads everything after `--` as the text to speak.
    if let Some(voice) = utterance.voice.as_deref() {
        command.arg("-v").arg(voice);
    }
    if let Some(rate) = utterance.rate {
        command.arg("-r").arg(rate.to_string());
    }

    // `--` guards against text that begins with `-` being read as a flag.
    command
        .arg("--")
        .arg(&utterance.text)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
}

/// Blank or whitespace-only names mean "system default" rather than a voice
/// literally called "". A name is never shell-interpolated — it is a separate
/// argv entry — so the only thing worth refusing is a leading `-`, which `say`
/// would read as the start of another flag if the argument order ever changed.
fn clean_voice(voice: Option<String>) -> Option<String> {
    let name = voice?.trim().to_string();
    if name.is_empty() || name.starts_with('-') {
        None
    } else {
        Some(name)
    }
}

/// Out-of-range rates clamp rather than refuse: a slider that silently does
/// nothing at its ends is worse than one that stops moving.
fn clean_rate(rate: Option<u32>) -> Option<u32> {
    rate.map(|value| value.clamp(RATE_MIN, RATE_MAX))
}

/// Enqueue a line to be spoken aloud. Empty/whitespace input is ignored.
///
/// `voice` is a name from [`list_voices`]; `rate` is words per minute. Both
/// default to the system setting when absent.
#[tauri::command]
pub fn speak(text: String, voice: Option<String>, rate: Option<u32>) {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return;
    }
    let speaker = speaker();
    speaker.queue.lock().unwrap().push_back(Utterance {
        text: trimmed.to_string(),
        voice: clean_voice(voice),
        rate: clean_rate(rate),
    });
    speaker.signal.notify_one();
}

/// Barge-in: discard everything queued and cut off the line now playing.
#[tauri::command]
pub fn stop_speaking() {
    let speaker = speaker();
    speaker.flush_gen.fetch_add(1, Ordering::SeqCst);
    speaker.queue.lock().unwrap().clear();
}

/// Every voice installed on this Mac, for the settings picker.
///
/// The installed set is per-machine — voices are downloaded in System Settings,
/// so hard-coding a list would offer the operator voices they do not have and
/// hide the ones they went and fetched.
#[tauri::command]
pub fn list_voices() -> Vec<Voice> {
    let output = match Command::new("/usr/bin/say").arg("-v").arg("?").output() {
        Ok(output) if output.status.success() => output.stdout,
        _ => return Vec::new(),
    };

    String::from_utf8_lossy(&output)
        .lines()
        .filter_map(parse_voice_line)
        .collect()
}

/// One line of `say -v '?'`, which is `<name> <locale> # <sample sentence>`.
///
/// Split from the right rather than the left: a name may contain spaces and
/// parentheses ("Eddy (English (UK))"), while the locale is always the single
/// token immediately before the `#`.
fn parse_voice_line(line: &str) -> Option<Voice> {
    let (head, sample) = line.split_once('#')?;
    let (name, locale) = head.trim_end().rsplit_once(char::is_whitespace)?;

    let name = name.trim();
    let locale = locale.trim();
    if name.is_empty() || locale.is_empty() {
        return None;
    }

    Some(Voice {
        name: name.to_string(),
        locale: locale.to_string(),
        sample: sample.trim().to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_plain_voice_line() {
        let voice = parse_voice_line("Albert              en_US    # Hello! My name is Albert.")
            .expect("should parse");

        assert_eq!(voice.name, "Albert");
        assert_eq!(voice.locale, "en_US");
        assert_eq!(voice.sample, "Hello! My name is Albert.");
    }

    #[test]
    fn keeps_spaces_and_parens_in_a_name() {
        // The real reason the split runs from the right. A left split on the
        // first space would name this voice "Eddy".
        let voice = parse_voice_line("Eddy (English (UK)) en_GB    # Hello! My name is Eddy.")
            .expect("should parse");

        assert_eq!(voice.name, "Eddy (English (UK))");
        assert_eq!(voice.locale, "en_GB");
    }

    #[test]
    fn rejects_a_line_with_no_comment() {
        assert!(parse_voice_line("Albert en_US").is_none());
    }

    #[test]
    fn a_blank_or_flag_shaped_voice_falls_back_to_the_system_default() {
        assert_eq!(clean_voice(Some("  ".into())), None);
        assert_eq!(clean_voice(Some("-v".into())), None);
        assert_eq!(
            clean_voice(Some(" Samantha ".into())),
            Some("Samantha".into())
        );
        assert_eq!(clean_voice(None), None);
    }

    #[test]
    fn rates_clamp_instead_of_vanishing() {
        assert_eq!(clean_rate(Some(1)), Some(RATE_MIN));
        assert_eq!(clean_rate(Some(9_000)), Some(RATE_MAX));
        assert_eq!(clean_rate(Some(200)), Some(200));
        assert_eq!(clean_rate(None), None);
    }

    #[test]
    fn the_real_say_binary_lists_voices_with_usable_names() {
        // Guards the parser against the format actually shipping differently
        // from the fixtures above. Skipped where /usr/bin/say is absent so the
        // suite still runs on Linux CI.
        if !std::path::Path::new("/usr/bin/say").exists() {
            return;
        }

        let voices = list_voices();
        assert!(!voices.is_empty(), "a Mac always ships voices");
        assert!(
            voices
                .iter()
                .all(|v| !v.name.is_empty() && v.locale.contains('_')),
            "every parsed row should carry a name and a locale"
        );
    }
}
