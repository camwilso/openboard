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
