#!/usr/bin/env node
"use strict";

/**
 * Derive a light-show timeline from a mono 16-bit WAV.
 *
 * No dependencies: reads PCM directly, builds an energy envelope, finds onsets, and
 * estimates tempo by autocorrelating the onset envelope. That is enough to drive lights
 * — we need beat times and where the song changes character, not transcription.
 *
 *   node the-final-countdown/analyse-audio.cjs <wav> [out.json]
 *
 * Lives beside the media it analyses rather than in a general tools folder: it has one
 * job, and `spectral.cjs` next to it is the only thing it requires.
 */

const fs = require("node:fs");

const FRAME_MS = 10;

function readWav(file) {
  const buf = fs.readFileSync(file);
  if (buf.toString("ascii", 0, 4) !== "RIFF") throw new Error("not a RIFF file");
  let offset = 12;
  let rate = 8000;
  let channels = 1;
  let data = null;
  while (offset + 8 <= buf.length) {
    const id = buf.toString("ascii", offset, offset + 4);
    const size = buf.readUInt32LE(offset + 4);
    const body = offset + 8;
    if (id === "fmt ") {
      channels = buf.readUInt16LE(body + 2);
      rate = buf.readUInt32LE(body + 4);
    } else if (id === "data") {
      data = buf.subarray(body, body + size);
    }
    offset = body + size + (size % 2);
  }
  if (!data) throw new Error("no data chunk");
  return { rate, channels, data };
}

/**
 * One-pole low-pass, used to isolate bass.
 *
 * Kick and bass carry the beat far more than overall loudness does, so brightness driven by
 * total energy tracks vocals and cymbals instead of the pulse you actually feel.
 */
function lowpass(samples, rate, cutoffHz) {
  const rc = 1 / (2 * Math.PI * cutoffHz);
  const dt = 1 / rate;
  const alpha = dt / (rc + dt);
  const out = new Float64Array(samples.length);
  let prev = 0;
  for (let i = 0; i < samples.length; i += 1) {
    prev += alpha * (samples[i] - prev);
    out[i] = prev;
  }
  return out;
}

function toMono({ data, channels }) {
  const count = Math.floor(data.length / 2 / channels);
  const out = new Float64Array(count);
  for (let i = 0; i < count; i += 1) out[i] = data.readInt16LE(i * channels * 2) / 32768;
  return out;
}

/**
 * Mid/side split.
 *
 * Lead vocals are almost always panned dead centre, so they largely cancel in
 * side = (L-R)/2 while surviving in mid = (L+R)/2. Comparing the two in the vocal band is
 * what lets us say "someone is singing here" without any source separation or model — and
 * without transcribing anything, which is not what we need.
 *
 * Mono input yields an empty side channel, so the vocal signal degrades to zero rather than
 * producing nonsense.
 */
function toMidSide({ data, channels }) {
  const count = Math.floor(data.length / 2 / channels);
  const mid = new Float64Array(count);
  const sideCh = new Float64Array(count);
  for (let i = 0; i < count; i += 1) {
    const l = data.readInt16LE(i * channels * 2) / 32768;
    const r = channels > 1 ? data.readInt16LE((i * channels + 1) * 2) / 32768 : l;
    mid[i] = (l + r) / 2;
    sideCh[i] = (l - r) / 2;
  }
  return { mid, side: sideCh };
}

/** One-pole high-pass, the complement of lowpass above. */
function highpass(samples, rate, cutoffHz) {
  const low = lowpass(samples, rate, cutoffHz);
  const out = new Float64Array(samples.length);
  for (let i = 0; i < samples.length; i += 1) out[i] = samples[i] - low[i];
  return out;
}

/** Crude band-pass: high-pass then low-pass. Enough to separate bands, not to be surgical. */
function bandpass(samples, rate, lowHz, highHz) {
  return lowpass(highpass(samples, rate, lowHz), rate, highHz);
}

/** RMS per frame over an arbitrary sample array. */
function rmsFrames(samples, rate) {
  const per = Math.round((rate * FRAME_MS) / 1000);
  const frames = Math.floor(samples.length / per);
  const out = new Float64Array(frames);
  for (let f = 0; f < frames; f += 1) {
    let sum = 0;
    for (let i = 0; i < per; i += 1) {
      const v = samples[f * per + i];
      sum += v * v;
    }
    out[f] = Math.sqrt(sum / per);
  }
  return out;
}

/** Scale to 0..1 against a high percentile, so one transient cannot flatten everything. */
function normalise(values, percentile = 0.98) {
  const sorted = [...values].filter((v) => v > 0).sort((a, b) => a - b);
  const ref = sorted.length ? sorted[Math.floor(sorted.length * percentile)] : 1;
  return values.map((v) => Math.max(0, Math.min(1, ref > 0 ? v / ref : 0)));
}

/** RMS per frame — the envelope everything else is derived from. */
function envelope({ rate, channels, data }) {
  const per = Math.round((rate * FRAME_MS) / 1000);
  const frames = Math.floor(data.length / 2 / channels / per);
  const out = new Float64Array(frames);
  for (let f = 0; f < frames; f += 1) {
    let sum = 0;
    for (let i = 0; i < per; i += 1) {
      const sample = data.readInt16LE(((f * per + i) * channels) * 2) / 32768;
      sum += sample * sample;
    }
    out[f] = Math.sqrt(sum / per);
  }
  return out;
}

/** Positive first difference: rises in energy are where beats live. */
function flux(env) {
  const out = new Float64Array(env.length);
  for (let i = 1; i < env.length; i += 1) out[i] = Math.max(0, env[i] - env[i - 1]);
  return out;
}

function movingAverage(values, radius) {
  const out = new Float64Array(values.length);
  for (let i = 0; i < values.length; i += 1) {
    let sum = 0;
    let n = 0;
    for (let j = Math.max(0, i - radius); j <= Math.min(values.length - 1, i + radius); j += 1) {
      sum += values[j];
      n += 1;
    }
    out[i] = sum / n;
  }
  return out;
}

/** Onsets: flux peaks that clear a local adaptive threshold. */
function onsets(fl) {
  const baseline = movingAverage(fl, 60);
  const times = [];
  const minGap = Math.round(120 / FRAME_MS); // ignore double-triggers under 120ms
  let last = -Infinity;
  for (let i = 1; i < fl.length - 1; i += 1) {
    if (fl[i] <= fl[i - 1] || fl[i] < fl[i + 1]) continue;
    if (fl[i] < baseline[i] * 1.8) continue;
    if (i - last < minGap) continue;
    times.push(i);
    last = i;
  }
  return times;
}

/** Tempo by autocorrelating the onset envelope over a plausible BPM range. */
function tempo(fl) {
  const minBpm = 90;
  const maxBpm = 170;
  const best = { bpm: 0, score: -1 };
  for (let bpm = minBpm; bpm <= maxBpm; bpm += 0.25) {
    const lag = Math.round((60 / bpm) * (1000 / FRAME_MS));
    let score = 0;
    for (let i = 0; i + lag < fl.length; i += 1) score += fl[i] * fl[i + lag];
    // Normalise so longer lags are not penalised for having fewer terms.
    score /= fl.length - lag;
    if (score > best.score) {
      best.score = score;
      best.bpm = bpm;
    }
  }
  return best.bpm;
}

/** Phase: the beat-grid offset that lands on the most onset energy. */
function phase(fl, bpm) {
  const period = (60 / bpm) * (1000 / FRAME_MS);
  let best = { offset: 0, score: -1 };
  for (let offset = 0; offset < period; offset += 0.25) {
    let score = 0;
    for (let beat = 0; ; beat += 1) {
      const idx = Math.round(offset + beat * period);
      if (idx >= fl.length) break;
      score += fl[idx];
    }
    if (score > best.score) best = { offset, score };
  }
  return best.offset;
}

/**
 * Section boundaries: sustained shifts in smoothed energy.
 *
 * Coarse on purpose — the goal is "the song changed character here", which is what a
 * colour change should follow.
 */
function sections(env) {
  const smooth = movingAverage(env, 150); // ~3s window
  const marks = [0];
  const minLen = Math.round(8000 / FRAME_MS); // sections at least 8s apart
  for (let i = minLen; i < smooth.length - minLen; i += 1) {
    const before = smooth[i - minLen / 2];
    const after = smooth[i + minLen / 2];
    if (before <= 0) continue;
    const ratio = after / before;
    if (ratio > 1.35 || ratio < 0.72) {
      if (i - marks.at(-1) >= minLen) marks.push(i);
    }
  }
  return marks;
}

const wav = process.argv[2];
if (!wav) {
  process.stderr.write("usage: analyse-audio.cjs <wav> [out.json]\n");
  process.exit(1);
}

const pcm = readWav(wav);
const env = envelope(pcm);
const fl = flux(env);
const bpm = tempo(fl);
const off = phase(fl, bpm);
const on = onsets(fl);
const sec = sections(env);

const toSec = (frame) => Math.round(frame * FRAME_MS) / 1000;
const period = (60 / bpm) * (1000 / FRAME_MS);
const beats = [];
for (let b = 0; ; b += 1) {
  const idx = off + b * period;
  if (idx >= env.length) break;
  beats.push(Math.round(idx * FRAME_MS) / 1000);
}

// Where the music actually starts: first sustained energy above a floor. The official
// video carries silence and non-musical intro before the song.
const floor = 0.02;
let musicStart = 0;
for (let i = 0; i < env.length - 50; i += 1) {
  let above = 0;
  for (let j = i; j < i + 50; j += 1) if (env[j] > floor) above += 1;
  if (above > 40) {
    musicStart = toSec(i);
    break;
  }
}

// Per-beat dynamics. This is what lets the show react to the music rather than just keep
// time with it: loud beats read bright, quiet passages stay restrained, and accents punch.
const { mid, side } = toMidSide(pcm);

// Bands chosen for what drives which lights:
//   bass    kick and bass guitar — the pulse you feel
//   vocal   300Hz-3kHz, where sung fundamentals and their first harmonics sit
//   high    cymbals, hats, the synth attack
// FFT bands, not filter cascades. One-pole filters roll off at 6dB/octave, so every
// "band" leaked the kick and the cymbals and all of them just tracked loudness — the
// centre-isolated signal showed no vocal structure at all. Proper bin summing separates.
const { spectrogram, bandEnergy } = require("./spectral.cjs");
const spec = spectrogram(mid, side, { rate: pcm.rate, fftSize: 2048, hopMs: FRAME_MS });
const specFrames = spec.midMag.length;

const bassRaw = new Float64Array(specFrames);
const highRaw = new Float64Array(specFrames);
const vocalRaw = new Float64Array(specFrames);
for (let f = 0; f < specFrames; f += 1) {
  bassRaw[f] =
    bandEnergy(spec.midMag[f], spec.binHz, 30, 120) +
    bandEnergy(spec.midMag[f], spec.binHz, 120, 250);
  highRaw[f] = bandEnergy(spec.midMag[f], spec.binHz, 2600, 7000);
  // Present in the middle, absent from the sides: lead vocals sit dead centre while
  // guitars, keys and reverb spread across the field. Verified against the song — the
  // instrumental break at ~230s drops here while every other band stays loud.
  const m = bandEnergy(spec.midMag[f], spec.binHz, 600, 2600);
  const sd = bandEnergy(spec.sideMag[f], spec.binHz, 600, 2600);
  vocalRaw[f] = Math.max(0, m - sd * 1.2);
}

const normEnergy = normalise(Array.from(env));
const normBass = normalise(Array.from(bassRaw), 0.9);
const normHigh = normalise(Array.from(highRaw), 0.9);
const normVocal = normalise(Array.from(vocalRaw), 0.95);


const round2 = (v) => Math.round(v * 100) / 100;
const frameAt = (t) => Math.min(env.length - 1, Math.max(0, Math.round((t * 1000) / FRAME_MS)));
// Spectral arrays are shorter than the envelope: an FFT frame needs a whole window.
const specAt = (i) => Math.min(specFrames - 1, Math.max(0, i));

// Accents are relative to OTHER BEATS, not to all frames. Thresholding against every frame
// marked 46% of beats as accents — because most beats contain at least one top-percentile
// frame, which makes "accent" meaningless.
const beatPeak = beats.map((t) => {
  const start = frameAt(t);
  const end = Math.min(env.length - 1, start + Math.round(period));
  let peak = 0;
  for (let i = start; i <= end; i += 1) peak = Math.max(peak, fl[i]);
  return peak;
});
const peakSorted = [...beatPeak].sort((a, b) => a - b);
const accentFloor = peakSorted[Math.floor(peakSorted.length * 0.88)] ?? Infinity;

const beatData = beats.map((t) => {
  const start = frameAt(t);
  // Look at the window from this beat to just before the next one.
  const end = Math.min(env.length - 1, start + Math.round(period));
  let peakFlux = 0;
  let energySum = 0;
  let bassPeak = 0;
  for (let i = start; i <= end; i += 1) {
    peakFlux = Math.max(peakFlux, fl[i]);
    energySum += normEnergy[i];
    bassPeak = Math.max(bassPeak, normBass[i]);
  }
  let vocalSum = 0;
  let highPeak = 0;
  let bassPeakSpec = 0;
  for (let i = start; i <= end; i += 1) {
    const si = specAt(i);
    vocalSum += normVocal[si];
    highPeak = Math.max(highPeak, normHigh[si]);
    bassPeakSpec = Math.max(bassPeakSpec, normBass[si]);
  }
  return {
    t,
    i: round2(energySum / Math.max(1, end - start + 1)),
    b: round2(bassPeakSpec),
    // Averaged, not peaked: a peak fires on one transient, where singing is sustained and
    // an average is what distinguishes a vocal phrase from a stray click.
    v: round2(vocalSum / Math.max(1, end - start + 1)),
    h: round2(highPeak),
    a: peakFlux >= accentFloor ? 1 : 0,
  };
});

// Section energy decides its "look" — a quiet intro should not be lit like a chorus.
const sectionData = sec.map((frame, idx) => {
  const next = idx + 1 < sec.length ? sec[idx + 1] : env.length;
  let sum = 0;
  for (let i = frame; i < next; i += 1) sum += normEnergy[i];
  return { t: toSec(frame), energy: round2(sum / Math.max(1, next - frame)) };
});

/**
 * Surges: sustained lifts in energy, not single transients.
 *
 * Compares a one-second window before each point with the second after, so a snare hit does not
 * qualify but the band arriving does. These are the moments worth an off-to-bright flash — the
 * lights going dark for an instant and then punching is what makes a lift feel like a lift.
 */
const surgeSmooth = movingAverage(env, 10);
const surgeMax = Math.max(...surgeSmooth);
const surgeNorm = Array.from(surgeSmooth, (v) => (surgeMax ? v / surgeMax : 0));
const surgeWindow = Math.round(1000 / FRAME_MS);
const surges = [];
for (let i = surgeWindow; i < surgeNorm.length - surgeWindow; i += 1) {
  let before = 0;
  let after = 0;
  for (let j = 0; j < surgeWindow; j += 1) {
    before += surgeNorm[i - surgeWindow + j];
    after += surgeNorm[i + j];
  }
  before /= surgeWindow;
  after /= surgeWindow;
  const jump = after - before;
  // 0.12 keeps the genuinely structural lifts; a lower bar fires on every bar line.
  if (jump < 0.12) continue;
  const last = surges.at(-1);
  // At least 2s apart, and keep the bigger of two nearby candidates.
  if (last && toSec(i) - last.t < 2) {
    if (jump > last.jump) surges[surges.length - 1] = { t: toSec(i), jump: round2(jump) };
    continue;
  }
  surges.push({ t: toSec(i), jump: round2(jump) });
}

const result = {
  source: wav,
  durationSec: toSec(env.length),
  frameMs: FRAME_MS,
  bpm: Math.round(bpm * 100) / 100,
  beatPeriodSec: Math.round((60 / bpm) * 1000) / 1000,
  musicStartSec: musicStart,
  beatCount: beats.length,
  accentCount: beatData.filter((b) => b.a).length,
  vocalBeatCount: beatData.filter((b) => b.v >= 0.35).length,
  stereo: pcm.channels > 1,
  sections: sectionData,
  surges,
  beats: beatData,
};

const out = process.argv[3];
if (out) fs.writeFileSync(out, JSON.stringify(result));
process.stdout.write(
  [
    `duration    ${result.durationSec}s`,
    `bpm         ${result.bpm}  (period ${result.beatPeriodSec}s)`,
    `music from  ${result.musicStartSec}s`,
    `beats       ${result.beatCount}`,
    `onsets      ${result.onsetCount}`,
    `accents     ${result.accentCount}`,
    `vocal beats ${result.vocalBeatCount} of ${result.beatCount}`,
    `surges      ${surges.map((x) => `${x.t}s(+${x.jump})`).join(" ")}`,
    `sections    ${result.sections.map((x) => `${x.t}s(${x.energy})`).join(" ")}`,
    "",
  ].join("\n"),
);
