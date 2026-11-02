# voice-cli — spike A-08

Throwaway terminal program that tries the whole voice chain on real hardware and prints
timings: microphone → wake word → voice-activity detection → speech-to-text → text-to-speech.
It is **not** the app and nothing in `src-tauri/` uses it. It writes no audio to disk (it only
reads WAV files you give it). Spec: `docs/spec.md` §6 and §10, task A-08; results go into the
S1 report (A-10).

Built on `sherpa-onnx` (one engine for all four stages, Apache-2.0) and `cpal` (audio I/O).
Models are **not** in the repo: you download them below. Check each model's licence before it
goes anywhere near the product (D-01).

## Get the program

Easiest: open the **spike-voice** workflow run on the PR (or run it with "Run workflow"),
download the artifact for your OS (`voice-cli-Windows`, `voice-cli-macOS`, `voice-cli-Linux`).
On macOS and Linux the download loses the executable bit, so run `chmod +x voice-cli` first.
On macOS also run `xattr -d com.apple.quarantine voice-cli`, or Gatekeeper blocks it.
Or build it: `cd spikes/voice-cli && cargo build --release` (needs Rust; Linux also needs
`libasound2-dev`).

## Get the models (Windows PowerShell; macOS/Linux: same URLs with `curl -LO` and `tar xjf`)

Windows tip: if `curl.exe` fails with a `schannel` / `SEC_E_INVALID_TOKEN` error, use
`[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12` and
`Invoke-WebRequest <url> -OutFile <file>`, or `Start-BitsTransfer`. Never turn off certificate checks.

```powershell
mkdir models; cd models
$b = "https://github.com/k2-fsa/sherpa-onnx/releases/download"
curl.exe -LO "$b/asr-models/silero_vad.onnx"
curl.exe -LO "$b/asr-models/sherpa-onnx-moonshine-tiny-en-int8.tar.bz2"
curl.exe -LO "$b/kws-models/sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01.tar.bz2"
curl.exe -LO "$b/tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2"
Get-ChildItem *.bz2 | ForEach-Object { tar xjf $_.Name }
```

Kokoro: make a folder with only `model.int8.onnx`, `voices.bin`, `tokens.txt` and the
`lexicon-*.txt` files (copy them, leave the rest). The `espeak-ng-data` folder is GPL-3.0 and is
not needed by sherpa-onnx 2.x, so keep it out.

Wake-word phrase file (`keywords.txt`, one line per phrase, tokens are the model's own BPE pieces):

```
▁HE Y ▁JA R VI S @hey_jarvis
▁JA R VI S @jarvis
```

## Run it

```powershell
.\voice-cli.exe devices
.\voice-cli.exe mic --seconds 5
.\voice-cli.exe transcribe --wav models\sherpa-onnx-moonshine-tiny-en-int8\test_wavs\0.wav `
  --vad models\silero_vad.onnx --asr moonshine --asr-dir models\sherpa-onnx-moonshine-tiny-en-int8
.\voice-cli.exe listen --vad models\silero_vad.onnx --asr moonshine `
  --asr-dir models\sherpa-onnx-moonshine-tiny-en-int8 --seconds 60
.\voice-cli.exe wake --kws-dir models\sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01 `
  --keywords keywords.txt --seconds 120
.\voice-cli.exe say --tts-dir models\kokoro --sid 24,26 --threads 4 `
  --text "Good evening, sir. Shall I open Chrome?"
```

## Benchmark: which speech-to-text model is best for you

```powershell
.\voice-cli.exe bench --vad models\silero_vad.onnx --threads 4 `
  --models "tiny=moonshine:models\sherpa-onnx-moonshine-tiny-en-int8,whisper=whisper:models\sherpa-onnx-whisper-base.en"
```

You get 30 command phrases, one at a time: press Enter, say the phrase clearly, and wait for
"recorded". Use `--count 10` for a shorter run. Audio is kept in memory only. Afterwards every
model decodes the **same** recordings and the program prints one table: word error rate (WER,
lower is better), phrases fully right, and average decode time. Each model appears twice:

- **whole**: everything you recorded. This shows how well the model understands you.
- **vad**: only the piece the voice detector cut out. If this is much worse than **whole**, the
  detector is clipping the start or end of your requests (the spec's 2 s pre-roll buffer is the fix).

No microphone? `--wav-list FILE` takes lines like `C:\clips\a.wav|open chrome` instead.

## What to paste back (issue #14 or the S1 report)

1. Your laptop model, CPU, RAM, Windows version, microphone and speakers.
2. `mic --seconds 5`: the "% of the expected count", stream errors and level lines. Peak 0 means
   the OS blocks the mic. Windows: Settings → Privacy → Microphone → desktop apps. macOS: the
   first `mic` or `listen` run asks the terminal app for microphone access; if it was denied,
   allow it in System Settings → Privacy & Security → Microphone, then rerun.
3. `listen` while you say 5 short requests: the STT time and "text ready … after end of speech".
4. `wake` for 2 minutes **silent** (false triggers), then saying "Jarvis" / "hey Jarvis" 10 times
   at normal and far distance (hits out of 10). Note the "busy %" line and, in Task Manager, the
   program's CPU % and memory.
5. `bench`: the whole table plus the list of first mistakes.
6. `say`: the time to first sound and the real-time factor per voice id; which id sounds like
   the British male voice (24 `bm_daniel`, 25 `bm_fable`, 26 `bm_george`, 27 `bm_lewis` in Kokoro **v1.0**; the v1.1 model has only three English voices and the rest are Chinese, so use v1.0). Try `--threads 2` and `--threads 4` and compare the first-sentence time..
7. Anything that crashed or sounded wrong.

## What this spike does NOT do

- No echo cancellation (D-05): run `say` and `listen` apart, or use headphones.
- The microphone callback allocates and uses a std channel; product code needs a lock-free ring.
- Linear resampling, one sentence at a time, no streaming TTS, no pre-roll buffer.
- "busy %" counts one thread; the Task Manager figure is the one that matters.
