# S1 voice spike report (task A-10) — draft, in progress

Status: **partial**. Gate G1 is not decided. This file records measurements as they arrive;
nothing here is a decision (decisions go in `docs/decisions.md`: D-02, D-03, D-04, D-05, D-20).

Tool: `spikes/voice-cli` (task A-08). Engine: `sherpa-onnx` 2.0.1 with `cpal`.
Budgets: spec §10.

## Machines

| Label | Machine | OS | Mic | Notes |
| --- | --- | --- | --- | --- |
| W1 | Owner's Windows laptop (model, CPU and RAM to be added) | Windows | Realtek array mic, 48 kHz, 2 ch | Not yet checked against the §10 reference machine (4 cores / 8 threads, 8 GB) |
| C1 | Cloud VM, Intel Xeon 2.1 GHz | Linux | none | Sample WAVs only; not a reference machine |

## Capture (W1)

| Check | Result |
| --- | --- |
| `mic --seconds 5` | 99.9% of the expected 16 kHz samples, 500 callbacks, 0 stream errors, level rms 0.0093 / peak 0.066 (quiet but usable) |

## Speech to text: Moonshine tiny (English, int8, MIT per spec) + Silero VAD

| Machine | Input | STT time | Real-time factor | Notes |
| --- | --- | --- | --- | --- |
| W1 | 6.6 s sample clip | 130 ms | 0.02 | Correct text; models load in 1.1 s |
| C1 | 6.6 s sample clip | 158 ms | 0.02 | Correct text |
| W1 | live, 3.6 s and 4.3 s of speech | 59 to 61 ms | about 0.015 | Teacher's voice across a noisy classroom: words wrong, which is the test conditions, not a verdict on the model |

End of speech to text on W1: about 760 ms, of which 700 ms is the VAD's silence window (spec §6.2
default) and about 60 ms is the model. Against §10 "End of speech → transcript (5 s utterance)":
hard limit 1.2 s **met**, target 0.5 s **not met with a 700 ms window**; it would be met with a
window near 400 ms, at the cost of cutting off slow speakers. To decide with data.

Standby cost while listening (VAD + STT, one thread): 1.8% of wall time. Not the Task Manager
figure, and the wake word was not running.

### Benchmark on W1: 30 command phrases read once (`bench`, 4 threads, quiet room, desk distance)

Raw table from the tool, then the corrected scores. The owner said "what **time** is the weather
like in Mumbai" (all three models wrote exactly that, so it is not an error), and models write
"552" for "five five two" (right for an assistant, but the first version of the tool counted it as
three errors; the tool now scores spoken digits as digit words).

| Model | Raw WER, whole | Raw phrases right | Corrected WER, whole | Corrected phrases right | Decode time per phrase |
| --- | --- | --- | --- | --- | --- |
| Moonshine tiny int8 | 9.6% | 23/30 | **6.6%** | **25/30** | 41 ms |
| Moonshine base int8 | 5.9% | 25/30 | **2.9%** | **27/30** | 76 ms |
| Whisper base.en | 5.1% | 26/30 | **2.2%** | **28/30** | 241 ms |

The corrected scores come from the complete lists of whole-recording mistakes (136 reference words).
One speaker, one session: a difference of one phrase between base and Whisper is noise.

What the mistakes were (whole recording):
- **"Jarvis" is the weak spot.** Tiny and base got it wrong in both phrases ("jawless", "jauis",
  "Javas", "jawis"); Whisper got one of two ("Jealous"). Speech-to-text cannot be trusted to spell the
  name; the wake word is a separate detector, and the orchestrator must not depend on the
  transcript containing "Jarvis".
- Word-splitting variants ("Re-name", "notepads", "node pad") and "list the apps I can open" →
  "list the apps icon open" (tiny and base). Harmless to a language model, wrong to an exact matcher.
- Proper nouns Mumbai, Spotify, Chrome were right in every whole recording.

End of speech to transcript (adds the 0.7 s silence window): tiny about 0.74 s, base about 0.78 s,
Whisper about 0.94 s, all inside the §10 limit of 1.2 s; the 0.5 s target needs a shorter window.
Moonshine base costs 35 ms more than tiny and cut word errors by more than half; Whisper's extra
165 ms over base bought about one phrase in thirty. Candidate for D-04: **Moonshine base**, with
Whisper base.en as the accuracy option. Not decided.

### The voice detector clips the start of requests

Every model scored worse on the detector's cut ("vad") than on the whole recording, by the same
amount: 3 more phrases wrong out of 30 for each model (WER +2.9 to +3.7 points). Examples from the
owner's run: "open Chrome" → "Open crew", "mute the microphone" → "Viewed the microphone",
"good evening Jarvis" → "evening", "find photos" → "5 photos", "read the file" → "hit the file".
The first sound of the phrase is cut off. On a sample file, padding the cut by 0.3 s before it
recovered half of the lost words and 0.6 s recovered all of them. This is the spec's pre-roll
(§6.2: keep the last 2 s in RAM); `bench --preroll 0.3,0.6` measures the amounts on a real run.
Still to do: run `bench` with the widened rows on W1 and pick the amount.

Open: WER on 100 command utterances in a quiet room, at 0.5 m and 1 m (needs the corpus, task A-09).

## Wake word (D-02): sherpa-onnx open-vocabulary KWS (zipformer 3.3M, GigaSpeech)

| Check | Result |
| --- | --- |
| Detects a test phrase in a sample WAV (C1) | Yes ("light up", 7.1 s of audio decoded in 192 ms) |
| "hey jarvis" false accepts per hour, false rejects at 1 m and 3 m | **Not measured** |
| CPU and RAM in standby on W1 | **Not measured** |

Phrase file uses the model's own BPE pieces: `▁HE Y ▁JA R VI S @hey_jarvis`.
Model licence: card says Apache-2.0; trained on GigaSpeech data. Check before shipping (D-20).

## Text to speech (D-03): Kokoro-82M int8 in lexicon-only mode

Use the **v1.0** package (`kokoro-int8-multi-lang-v1_0`, 54 speaker ids). The v1.1 package has
only three English voices (ids 0 to 2: `af_maple`, `af_sol`, `bf_vale`); every other id is a
Chinese voice. A first run on W1 with ids 24 to 27 on v1.1 sounded like Chinese women for that reason.

| Check | Result |
| --- | --- |
| Loads and speaks without espeak-ng (sherpa-onnx 2.x) | Yes (C1 and W1) |
| Real-time factor, 2 threads, v1.1 (same model size) | W1: 1.1 to 1.6. C1: 1.1 to 1.7 |
| Time to generate the first sentence, 2 threads (1.4 to 1.5 s of speech) | W1: 1.6 to 2.4 s. §10 "end of speech to first audio, local intent": hard 1.5 s, target 0.8 s. **Not met as configured** |
| Speaker start delay after `play()` | W1: 120 to 350 ms |
| Generation slower than playback (RTF above 1) | Gaps between sentences in a long reply unless generation is overlapped with playback or made faster |
| Listening test, Kokoro v1.0 on W1 | Owner shortlists `bm_daniel` (24) and `bm_george` (26) as good; no blind audition yet |
| Threads on W1 (Kokoro v1.0, `bm_daniel`), first sentence of 1.4 s of speech | 2 threads: 1.5 to 1.8 s (RTF 1.0 to 1.25). **4 threads: 1.37 to 1.50 s (RTF 0.88 to 0.97), the best.** 6 threads: 1.44 s (RTF 1.0 to 1.1). 8 threads: 1.58 s (RTF 1.1). More than 4 does not help |
| Estimated end of speech to first audio, local intent, W1 CPU | about 0.76 s (speech to text) + 1.4 s (first voice sentence) + 0.2 s (speaker start) = about 2.4 s, against the advisory 1.5 s limit (see D-21) |
| Playback bug found by the owner | The last word was cut ("Chrome" heard as "chro"): the spike's player stopped before the device buffer drained. Fixed with trailing silence; not a voice problem |
| Effect of a shorter first chunk, a smaller voice model, or the GPU (`--provider`) | **Not measured yet** |
| Out-of-vocabulary names in lexicon-only mode | **Not measured** (judge by ear with a name list) |
| Blind audition, 5 listeners | **Not done** |

## Echo and interruption (D-05)

Not started. The spike has no echo cancellation: test `say` and `listen` apart, or with headphones.

## Gate G1

Not decided. Missing: wake-word FA/FR, W1 TTS speed and voice choice, quiet-room WER, a second
machine (Mac numbers are expected from the other developer), the §10 reference-machine spec.
