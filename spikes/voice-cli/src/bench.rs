//! `bench`: the same audio through several speech-to-text models, with word error rate (WER).
//!
//! Audio comes from the microphone (press Enter, say the phrase) or from WAV files, is kept
//! in memory only, and is decoded twice per take: the whole recording ("whole") and the
//! piece the voice-activity detector cut out ("vad"). A gap between the two means the
//! detector clipped the start or end of the request, not that the model misheard.

use crate::{audio, models, ms, transcribe_samples, Args};
use sherpa_onnx::{LinearResampler, VoiceActivityDetector, Wave};
use std::io::BufRead;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// Command-style phrases, no digits (so number formatting does not count as an error).
/// Mixes common words with names a speech model is likely to trip on.
const PHRASES: &[&str] = &[
    "open Chrome",
    "what time is it",
    "what is the date today",
    "what is my battery level",
    "how much memory is free",
    "open the calculator",
    "find my tax return",
    "find my tax return from last year",
    "open Chrome and find my tax return from last year",
    "rename this file to budget",
    "move the report to my documents folder",
    "read the file called notes",
    "list the apps I can open",
    "remember that my door code is five five two",
    "mute the microphone",
    "stop talking",
    "cancel that",
    "what can you do",
    "open Spotify",
    "open Notepad",
    "search my downloads for invoices",
    "how is my computer doing",
    "good evening Jarvis",
    "thank you Jarvis",
    "what is the weather like in Mumbai",
    "tell me a joke",
    "open Visual Studio Code",
    "find photos from last summer",
    "show me my recent files",
    "open the settings",
];

struct Take {
    reference: String,
    whole: Vec<f32>,
    segment: Option<Vec<f32>>,
}

/// Lower case, letters, digits and apostrophes only, split into words.
fn normalise(s: &str) -> Vec<String> {
    s.to_lowercase()
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '\'' {
                c
            } else {
                ' '
            }
        })
        .collect::<String>()
        .split_whitespace()
        .map(str::to_string)
        .collect()
}

fn edit_distance(a: &[String], b: &[String]) -> usize {
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for (i, x) in a.iter().enumerate() {
        let mut cur = vec![i + 1];
        for (j, y) in b.iter().enumerate() {
            let sub = prev[j] + usize::from(x != y);
            cur.push(sub.min(prev[j + 1] + 1).min(cur[j] + 1));
        }
        prev = cur;
    }
    prev[b.len()]
}

/// `name=kind:dir,name2=kind2:dir2` (the folder may contain `:`, as in `C:\models`).
fn parse_models(s: &str) -> Result<Vec<(String, String, PathBuf)>, String> {
    s.split(',')
        .filter(|p| !p.trim().is_empty())
        .map(|part| {
            let (name, rest) = part
                .split_once('=')
                .ok_or_else(|| format!("{part:?}: expected name=kind:folder"))?;
            let (kind, dir) = rest
                .split_once(':')
                .ok_or_else(|| format!("{part:?}: expected name=kind:folder"))?;
            Ok((
                name.trim().to_string(),
                kind.trim().to_string(),
                PathBuf::from(dir.trim()),
            ))
        })
        .collect()
}

#[derive(Default)]
struct Score {
    errors: usize,
    ref_words: usize,
    exact: usize,
    takes: usize,
    stt: Duration,
    misses: Vec<(String, String)>,
}

impl Score {
    fn add(&mut self, reference: &str, hypothesis: &str, took: Duration) {
        let (r, h) = (normalise(reference), normalise(hypothesis));
        self.errors += edit_distance(&r, &h);
        self.ref_words += r.len();
        self.takes += 1;
        self.stt += took;
        if r == h {
            self.exact += 1;
        } else if self.misses.len() < 8 {
            self.misses
                .push((reference.to_string(), hypothesis.to_string()));
        }
    }
    fn wer(&self) -> f64 {
        100.0 * self.errors as f64 / self.ref_words.max(1) as f64
    }
}

/// Records one take: from "Enter" until the detector has cut a segment (plus 0.3 s of tail)
/// or the window runs out.
fn record_take(
    cap: &audio::Capture,
    vad: &VoiceActivityDetector,
    window: Duration,
) -> (Vec<f32>, Option<Vec<f32>>) {
    for _ in cap.rx.try_iter() {}
    vad.reset();
    let (mut whole, mut segment, mut stop_at) = (Vec::new(), None, None::<Instant>);
    let deadline = Instant::now() + window;
    while Instant::now() < deadline && stop_at.is_none_or(|t| Instant::now() < t) {
        let Ok(chunk) = cap.rx.recv_timeout(Duration::from_millis(50)) else {
            continue;
        };
        whole.extend_from_slice(&chunk);
        vad.accept_waveform(&chunk);
        if segment.is_none() && !vad.is_empty() {
            if let Some(s) = vad.front() {
                segment = Some(s.samples().to_vec());
            }
            vad.pop();
            stop_at = Some(Instant::now() + Duration::from_millis(300));
        }
    }
    if segment.is_none() {
        vad.flush();
        if !vad.is_empty() {
            if let Some(s) = vad.front() {
                segment = Some(s.samples().to_vec());
            }
            vad.pop();
        }
    }
    (whole, segment)
}

fn take_from_wav(path: &str, reference: &str, vad: &VoiceActivityDetector) -> Result<Take, String> {
    let wav = Wave::read(path).ok_or_else(|| format!("cannot read {path}"))?;
    let mut samples = wav.samples().to_vec();
    if wav.sample_rate() != audio::STT_RATE {
        let rs = LinearResampler::create(wav.sample_rate(), audio::STT_RATE).ok_or("resampler")?;
        samples = rs.resample(&samples, true);
    }
    vad.reset();
    let mut segment = None;
    for chunk in samples.chunks(1600) {
        vad.accept_waveform(chunk);
        if segment.is_none() && !vad.is_empty() {
            if let Some(s) = vad.front() {
                segment = Some(s.samples().to_vec());
            }
        }
        while !vad.is_empty() {
            vad.pop();
        }
    }
    if segment.is_none() {
        vad.flush();
        if let Some(s) = vad.front() {
            segment = Some(s.samples().to_vec());
        }
        while !vad.is_empty() {
            vad.pop();
        }
    }
    Ok(Take {
        reference: reference.to_string(),
        whole: samples,
        segment,
    })
}

fn read_lines(path: &str) -> Result<Vec<String>, String> {
    let text =
        std::fs::read_to_string(Path::new(path)).map_err(|e| format!("cannot read {path}: {e}"))?;
    Ok(text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(str::to_string)
        .collect())
}

pub fn run(a: &Args) -> Result<(), String> {
    let vad = models::vad(a.need("vad")?, a.num("silence", 0.7)?)?;
    let specs = parse_models(a.need("models")?)?;
    if specs.is_empty() {
        return Err("--models needs at least one name=kind:folder".into());
    }
    let mut takes: Vec<Take> = Vec::new();
    if let Some(list) = a.get("wav-list") {
        for line in read_lines(list)? {
            let (path, reference) = line
                .split_once('|')
                .ok_or_else(|| format!("{line:?}: expected path|reference text"))?;
            takes.push(take_from_wav(path.trim(), reference.trim(), &vad)?);
        }
    } else {
        let mut phrases: Vec<String> = match a.get("phrases") {
            Some(f) => read_lines(f)?,
            None => PHRASES.iter().map(|s| (*s).to_string()).collect(),
        };
        phrases.truncate(a.num("count", phrases.len())?);
        let window = Duration::from_secs_f32(a.num("window", 7.0)?);
        let cap = audio::Capture::start(a.get("device"))?;
        println!("microphone: {:?}", cap.device_name);
        println!("For each phrase: press Enter, then say it clearly at your normal volume.");
        println!(
            "Audio stays in memory and is never written to disk. {} phrases.\n",
            phrases.len()
        );
        let stdin = std::io::stdin();
        for (i, phrase) in phrases.iter().enumerate() {
            print!(
                "[{}/{}] Enter, then say:  \"{phrase}\"  ",
                i + 1,
                phrases.len()
            );
            std::io::Write::flush(&mut std::io::stdout()).ok();
            stdin
                .lock()
                .read_line(&mut String::new())
                .map_err(|e| e.to_string())?;
            let (whole, segment) = record_take(&cap, &vad, window);
            println!(
                "   recorded {:.1} s{}",
                whole.len() as f64 / 16_000.0,
                if segment.is_none() {
                    " (no speech heard)"
                } else {
                    ""
                }
            );
            takes.push(Take {
                reference: phrase.clone(),
                whole,
                segment,
            });
        }
    }

    let (threads, provider) = (a.num("threads", 4)?, a.get("provider").unwrap_or("cpu"));
    println!(
        "\n{} takes. Decoding the same audio with {} model(s)...\n",
        takes.len(),
        specs.len()
    );
    let unheard = takes.iter().filter(|t| t.segment.is_none()).count();
    println!(
        "{:<10} {:<6} {:>7} {:>9} {:>10}",
        "model", "audio", "WER", "exact", "avg STT"
    );
    let mut all_misses = Vec::new();
    for (name, kind, dir) in &specs {
        let rec = models::asr(kind, dir, threads, provider)?;
        let (mut whole, mut cut) = (Score::default(), Score::default());
        for t in &takes {
            let (h, d) = transcribe_samples(&rec, &t.whole);
            whole.add(&t.reference, &h, d);
            let (h, d) = t
                .segment
                .as_ref()
                .map_or((String::new(), Duration::ZERO), |s| {
                    transcribe_samples(&rec, s)
                });
            cut.add(&t.reference, &h, d);
        }
        for (label, sc) in [("whole", &whole), ("vad", &cut)] {
            println!(
                "{:<10} {:<6} {:>6.1}% {:>5}/{:<3} {:>7.0} ms",
                name,
                label,
                sc.wer(),
                sc.exact,
                sc.takes,
                ms(sc.stt) / sc.takes.max(1) as f64
            );
        }
        all_misses.push((name.clone(), whole.misses, cut.misses));
    }
    println!("\n\"whole\" = everything recorded; \"vad\" = what the voice detector cut out. If vad is much worse than whole, the detector is clipping the start or end of requests.");
    if unheard > 0 {
        println!("The detector heard no speech in {unheard} take(s) (counted as empty text in the vad rows).");
    }
    for (name, whole, cut) in all_misses {
        for (label, misses) in [("whole", whole), ("vad", cut)] {
            if misses.is_empty() {
                continue;
            }
            println!("\n{name} / {label}: first mistakes");
            for (r, h) in misses {
                println!("  said: {r:?}\n   got: {h:?}");
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(s: &str) -> Vec<String> {
        normalise(s)
    }

    #[test]
    fn normalise_ignores_case_and_punctuation_but_keeps_apostrophes() {
        assert_eq!(
            w("Open, Chrome! What's up?"),
            ["open", "chrome", "what's", "up"]
        );
    }

    #[test]
    fn edit_distance_counts_substitutions_insertions_and_deletions() {
        assert_eq!(edit_distance(&w("a b c"), &w("a b c")), 0);
        assert_eq!(edit_distance(&w("a b c"), &w("a x c")), 1);
        assert_eq!(edit_distance(&w("a b c"), &w("a c")), 1);
        assert_eq!(edit_distance(&w("a c"), &w("a b c")), 1);
        assert_eq!(edit_distance(&w(""), &w("a b")), 2);
    }

    #[test]
    fn score_reports_word_error_rate_and_exact_matches() {
        let mut s = Score::default();
        s.add("open chrome", "Open Chrome.", Duration::from_millis(10));
        s.add(
            "find my tax return",
            "find my tax returns",
            Duration::from_millis(30),
        );
        assert_eq!((s.errors, s.ref_words, s.exact, s.takes), (1, 6, 1, 2));
        assert!((s.wer() - 100.0 / 6.0).abs() < 1e-9);
        assert_eq!(s.misses.len(), 1);
    }

    #[test]
    fn model_specs_allow_a_drive_letter_in_the_folder() {
        let m = parse_models(r"tiny=moonshine:C:\models\tiny,whisper=whisper:models\w").unwrap();
        assert_eq!(
            m[0],
            (
                "tiny".into(),
                "moonshine".into(),
                PathBuf::from(r"C:\models\tiny")
            )
        );
        assert_eq!(m[1].1, "whisper");
        assert!(parse_models("nonsense").is_err());
    }

    #[test]
    fn the_built_in_phrases_have_no_digits() {
        assert!(PHRASES
            .iter()
            .all(|p| !p.chars().any(|c| c.is_ascii_digit())));
        assert_eq!(PHRASES.len(), 30);
    }
}
