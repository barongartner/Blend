# How Blend works

The whole pipeline, for when something sounds wrong and you want to know which
stage to blame. File names refer to `Sources/`.

## 1. Getting audio

| Song comes from | What happens | Where |
|---|---|---|
| Apple Music (subscription) | Recorded from the Music app through a Core Audio process tap, muted at the speaker, into `~/Library/Application Support/Blend/Captures/<persistentID>.caf` (32-bit float, the tap's sample rate). Real time. | `Audio/MusicCapture.swift` |
| Local file in the Music library (purchased, ripped) | Opened directly. | `Library/MusicBridge.swift` decides |
| Imported file (MP3 mode) | Opened directly. | `Model/Services.swift` |

Capture flow: make sure Music is running → find its audio process object
(Music has to have made a sound since launch, so the first capture of a session
starts the song, waits for the object, then restarts from the top) → create the
tap and a private aggregate device on the default output (the output device
must be the aggregate's main sub-device or the tap delivers silence) → IOProc
appends frames → play the song alone in a "Blend Capture" playlist with repeat
off → poll Music every 300 ms until it stops → trim leading and trailing digital
silence → write the CAF.

Every file is decoded to stereo float at the mix sample rate (48 kHz by
default) by `Audio/AudioDecoder.swift`, with AVAudioConverter resampling when
needed.

## 2. Analysis (`Analysis/`)

Works on a mono copy decimated to half the sample rate (22.05 / 24 kHz).

**Onsets.** 2048-point STFT, hop 512, 96-band log-mel spectrogram; onset
strength = mean positive spectral flux, with a 0.6 s moving mean removed.

**Tempo.** Autocorrelation of the onset envelope gives candidate lags (local
peaks, weighted by a log-normal prior centred on 118 BPM and by support from the
double lag), folded into 68–150 BPM. Each candidate is refined by a **comb
filter**: a phase histogram of the strongest energy rises in a 1 ms RMS
envelope, searched ±3% in 0.1 then 0.005 BPM steps; the sharpest histogram
wins, and a tempo within a hair of a whole or half BPM snaps to it (producers
set integers). Quantized songs come out at exactly 128.00.

**Beat phase.** The full-band histogram peak is precise but can sit on the
off-beat: in sidechained EDM the biggest energy rise is the synths swelling
back between kicks. So two candidate phases (the full-band peak and the peak of
discrete low-band attacks) and their half-beat alternatives are scored by the
**jump score** — how much louder the < 150 Hz band is in the 70 ms after the
grid beats than in the 70 ms before. Kicks and bass notes start on the beat,
so the true phase scores high and the off-beat scores about 1. A final ±60 ms
search with a 30 ms window lands on the start of the attack.

**Downbeat.** Of the four beat phases, the one whose beats carry the most
low-band onset energy plus the largest spectral change across the beat
(sections and chords change on downbeats).

**Beat list and confidence.** The Ellis dynamic-programming beat tracker runs
on the onset envelope for display; confidence combines comb sharpness, jump
clarity and how many tracked beats sit on the grid.

**Key.** Chroma from an 8192-point STFT over 55 Hz–1.76 kHz, correlated with
the Krumhansl-Kessler major/minor profiles; mapped to the Camelot wheel.

**Suggested in/out.** RMS per bar; the first and last bar above half the median
level (intro skip capped at 32 bars).

Results are cached as JSON in `Application Support/Blend/Analysis`, keyed by
song and versioned — bump `TrackAnalysis.currentVersion` when the analyzer
changes and every song is re-analyzed on next use.

## 3. Layout (`Engine/Timeline.swift`)

Every song's output is four regions:

```
 entry | ramp | body | outro
```

- **entry** — overlaps the previous song's outro; played at rate ρ = previous
  BPM ÷ own BPM (after folding octaves) so the tempos match. Only if
  0.8 ≤ ρ ≤ 1.25; otherwise ρ = 1 and the row shows a warning.
- **ramp** — alone, rate easing linearly (in output time) from ρ back to 1
  over the chosen number of bars. Closed form, so the sample count is exact.
- **body** — alone at its own tempo.
- **outro** — overlaps the next song's entry, at rate 1. Length = overlap
  bars × this song's bar length. The next song starts exactly here.

Everything is in integer output samples. The length readout is
`tracks.last.end / sampleRate`; the renderer walks the same numbers, so the
readout equals the file. If a song is too short for the overlaps around it the
ramp is sacrificed first, then the outro, with a warning.

With in and out points on downbeats (the snap button) and ρ applied, bar
lines coincide through every overlap.

## 4. Rendering (`Engine/`)

- **Spans.** Each song is rendered once into its whole output span.
  Stretched regions (entry + ramp) go through `TimeStretch.swift`: WSOLA with
  2048-sample grains, 1024 hop, ±8 ms similarity search, driven by the exact
  output→source position map, so beats stay where the layout says. Rate-1
  regions are a straight copy; a 1024-sample crossfade hides the seam. Key
  lock off = linear-interpolation varispeed instead.
- **Level.** Each span is scaled so its RMS over the used part hits −16 dBFS
  (max +10 dB), times the song's manual gain.
- **Transitions** (`MixRenderer.blend`): equal-power crossfade; **bass swap**
  = Linkwitz-Riley 4th-order split at 200 Hz on both songs, highs crossfade,
  lows hand over across one beat at the midpoint; **filter sweep** = outgoing
  through a low-pass sweeping 18 kHz→140 Hz (log) under a cosine fade, incoming
  through a high-pass opening 1.5 kHz→20 Hz; **cut** = no overlap, 5 ms
  anti-click fades.
- **Composition** writes any output range from the spans (solo regions) and the
  blended overlaps, applies the 10 ms start fade and the end fade, and streams
  5-second chunks to a float CAF master, evicting songs that are finished so
  only two or three are in memory.
- **Export** (`Exporter`): peak-normalize to −1 dBFS if the master exceeds it,
  then WAV 16/24-bit or AAC through AVAudioFile, or MP3 320 kbps through ffmpeg
  (TrackForge's downloaded copy, Homebrew, or PATH).

## 5. Tests

`Tests/main.swift` synthesizes two drum-machine songs (124 and 128 BPM, known
beat phase, chord changes on downbeats) and checks: tempo within 0.15 BPM,
downbeat within 15 ms, layout arithmetic, render length = layout length, kicks
of the two songs within 12 ms of each other through the overlap, tempo back to
128 after the ramp, WAV/MP3 durations. `--mix` does the same with real files
and measures kick alignment inside each overlap where both sides have clear
kicks.
