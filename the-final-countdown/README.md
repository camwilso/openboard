# Mapping a song

Fun mode plays a video full-screen and drives the whole pad in time with it. Two files
make that work, and neither ships with the repo:

| | |
|---|---|
| a video | any `.mp4`, `.mov` or `.m4v` — the first one found is used |
| `analysis.json` | the beat grid, generated from the song's audio |

The video is not here because it is ~90MB and not ours to redistribute. `analysis.json`
**is** committed, so if you have the same video the show works with no further work.

## Where songs live

Each song is one folder, holding those two files, inside the media library:

```
~/Library/Application Support/OpenBoard/Media/
    the-final-countdown/
        Europe - The Final Countdown.mp4
        analysis.json
    africa/
        toto-africa.mp4
        analysis.json
```

The app creates `Media/` on launch. Keep as many songs as you like — with one folder it
plays that one; with several it plays the first by name and logs which, along with how
to change it. To choose, put the folder's name in
`~/Library/Application Support/OpenBoard/config.json`:

```json
"countdown": { "mediaDir": "africa" }
```

A **name** picks from the library. A **path** — anything containing `/` or starting with
`~` — is used literally, so a song can live on an external drive if it is too big to
keep in Application Support.

This folder in the repo is only the tooling. It also works as a song folder when you run
from the source tree, which is why it is still checked for.

## Adding a song

### 1. Make its folder

```sh
mkdir -p ~/Library/Application\ Support/OpenBoard/Media/your-song
cp ~/Downloads/your-song.mp4 ~/Library/Application\ Support/OpenBoard/Media/your-song/
```

Only the extension matters. The app takes the first video file in the folder, so keep
one video per folder.

### 2. Extract mono audio

The analyser reads PCM WAV directly and has no dependencies, so the audio has to arrive
as a plain WAV. Anything that decodes will do; `ffmpeg` is the usual one:

```sh
ffmpeg -i ~/Downloads/your-song.mp4 \
       -ac 1 -ar 22050 -c:a pcm_s16le \
       /tmp/audio.wav
```

Mono 16-bit is what it expects. 22 kHz is plenty — this is looking for onsets and
tempo, not transcribing anything, and a smaller file analyses faster.

### 3. Generate the grid

```sh
node the-final-countdown/analyse-audio.cjs \
     /tmp/audio.wav \
     ~/Library/Application\ Support/OpenBoard/Media/your-song/analysis.json
```

It prints the tempo it found. Sanity-check that number against the song before trusting
the show: if it comes back at half or double the real BPM — which happens on tracks with
a strong off-beat — the lights will feel like they are lagging or racing rather than
being wrong in any obvious way.

## What it produces

```
bpm, beatPeriodSec      the tempo, and one beat in seconds
musicStartSec           where the first beat lands, so the show can wait for it
beats, accents          every beat, and the ones that hit harder
sections, surges        where the song changes character
stereo                  left/right energy, which is what makes the ring sweep
```

## Then set the intro

One value is not derived and has to be measured: **the moment the show stops counting
up and the first flash lands.** In `~/Library/Application Support/OpenBoard/config.json`:

```json
"countdown": { "introFlashSec": 13.2 }
```

For The Final Countdown that is 13.2s — the downbeat the whole intro builds toward. For
another song, pick the moment the track properly starts and put it here. Until then the
ring stays dark for the first 13.2 seconds of your song for no reason, and the show
looks broken when it is only waiting.

`leadMs` in the same block fires every cue slightly early to cancel a ~86ms ring write
plus audio latency. 70 works on this hardware; raise it if the lights trail the beat,
lower it if they run ahead.

Both values are per-song and there is only one of each, so switching songs means
revisiting them.

---

# How the mapping works

Moved here from the main README, which is for people using OpenBoard rather than people
changing how it listens.

The beat grid and the dynamics are derived, not guessed. `the-final-countdown/analyse-audio.cjs` reads a
mono WAV with no dependencies: RMS envelope, positive first difference as an onset signal,
tempo by autocorrelating that, then the grid phase landing on the most onset energy. It also
emits per beat:

| Field | What | Why |
|---|---|---|
| `i` | overall intensity 0–1 | how big the moment is |
| `b` | **bass** 30–250Hz | the pulse you feel |
| `h` | **highs** 2.6–7kHz | cymbals, hats, synth attack |
| `v` | **centre-channel lead** 600–2.6kHz | tracks the singing — see below |
| `a` | accent flag | thresholded against *other beats*, not all audio frames; against frames it flagged 46% of beats |

Bands are summed from FFT bins, not filtered. An earlier version cascaded one-pole filters,
which roll off at 6dB/octave — every "band" leaked the kick and the cymbals, so all of them
just tracked loudness and the vocal signal had no verse/chorus shape whatsoever.

### Voice detection, honestly

`v` is **centre-channel lead presence**, not voice recognition and not lyrics. Lead vocals are
mixed dead centre, so they survive in `mid = (L+R)/2` and largely cancel in
`side = (L−R)/2`; what is in the middle but not in the sides, within 600–2.6kHz, tracks the
singing well.

Evidence it is doing more than following volume: at ~230s every other band stays loud while
`v` drops to 0.22 — the instrumental break. Intro and outro sit near 0.00, the biggest chorus
peaks at 0.66.

It will not survive a mono mix, a centre-panned lead instrument, or a song where the vocal is
deliberately spread.

### Key roles

| Keys | Follow |
|---|---|
| 1–2 (top row) | the voice — warm near-white, so it reads as a different *kind* of thing |
| 3–4 | bass |
| 5–6 | highs |

Levels are scaled against the **recent** few seconds, not the whole song: absolute bass sits
at 0.94–1.00 for three minutes in this mix, so keys driven by raw level would simply stay on.
A flat window falls back to the absolute level — otherwise a signal pegged at maximum scales
to zero and the keys go dark exactly when the music is loudest.

Each key is rewritten only when its quantised value changes. Six keys plus the ring at ~80ms
a write is ~560ms, longer than a 504ms beat.

Sections carry an energy figure, which picks the look:

| Section energy | Style | Ring | Keys |
|---|---|---|---|
| < 0.25 | **ember** | dim slow breath | every 8 beats |
| < 0.45 | **pulse** | solid, gradient on downbeats | every 4 |
| < 0.65 | **sweep** | snake on downbeats | every 2 |
| ≥ 0.65 | **blaze** | complementary hues alternating each beat | every beat |

Color is HSL rather than a fixed palette: each section takes a base hue at least 60° from
its neighbour, drifting as the section plays so a long chorus does not sit on one color. An
accent is the *same hue, hotter* — a hue-shifted flash reads as a mistake, a brighter version
of the current color reads as a hit.

### Timing

Sync is **closed-loop** on QuickTime's playhead, with three corrections that each came from a
measurement:

| Measured | Correction |
|---|---|
| `play` returns before the playhead moves — an 88ms call, then a read of `0.000` | wait for the playhead to advance before anchoring, or the opening seconds run against a stopped clock |
| A playhead read costs **~100ms** round-trip | keep the fastest of several samples and credit each to the midpoint of its own round-trip |
| Awaiting that read in the beat loop stalled **a fifth of a 504ms beat** every 3s | re-anchor fire-and-forget, applying the result when it lands |
| A ring write takes **~86ms**, a key write ~79ms, plus audio output delay | fire every cue `leadMs` early |

Everything left over is a single constant, so there is one dial:

```bash
# countdown.leadMs in ~/Library/Application Support/OpenBoard/config.json
#   lights trailing the beat? raise it.  running ahead? lower it.
```

Default 110ms (`countdown.leadMs`).

The ring gets every beat; the keys change on the style's cadence. Painting everything every
beat cost ~245ms of a 504ms beat and the lights fell behind the music.

```bash
afconvert -f WAVE -d LEI16@8000 -c 1 <video> the-final-countdown/audio-8k.wav
node the-final-countdown/analyse-audio.cjs \
     the-final-countdown/audio-8k.wav the-final-countdown/analysis.json
```

`analysis.json` is committed (4.6KB); the video and WAV are not. Sync is **closed-loop**
against QuickTime's playhead rather than a start timestamp — over four minutes an
open-loop timer drifts, and it cannot tell that you paused, scrubbed or quit, so the lights
would dance on regardless.
