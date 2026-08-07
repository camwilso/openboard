"use strict";

/**
 * Minimal radix-2 FFT and band energies.
 *
 * The first attempt used cascaded one-pole filters, which roll off at 6dB/octave — so a
 * "300-3000Hz band" leaked most of the kick and most of the cymbals, and every band ended up
 * tracking overall loudness. Proper bin summing gives actual separation.
 */

/** In-place iterative FFT. `re`/`im` must be power-of-two length. */
function fft(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i += 1) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      [re[i], re[j]] = [re[j], re[i]];
      [im[i], im[j]] = [im[j], im[i]];
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len;
    const wRe = Math.cos(ang);
    const wIm = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let curRe = 1;
      let curIm = 0;
      for (let k = 0; k < len / 2; k += 1) {
        const aRe = re[i + k];
        const aIm = im[i + k];
        const bRe = re[i + k + len / 2] * curRe - im[i + k + len / 2] * curIm;
        const bIm = re[i + k + len / 2] * curIm + im[i + k + len / 2] * curRe;
        re[i + k] = aRe + bRe;
        im[i + k] = aIm + bIm;
        re[i + k + len / 2] = aRe - bRe;
        im[i + k + len / 2] = aIm - bIm;
        const nextRe = curRe * wRe - curIm * wIm;
        curIm = curRe * wIm + curIm * wRe;
        curRe = nextRe;
      }
    }
  }
}

const hann = (size) =>
  Float64Array.from({ length: size }, (_, i) => 0.5 * (1 - Math.cos((2 * Math.PI * i) / (size - 1))));

/**
 * Magnitude spectra per hop for two channels at once.
 *
 * Both channels are transformed on the same grid so their spectra can be compared bin by
 * bin — which is what centre-isolation needs.
 */
function spectrogram(mid, side, { rate, fftSize = 2048, hopMs = 10 }) {
  const hop = Math.round((rate * hopMs) / 1000);
  const win = hann(fftSize);
  const frames = Math.max(0, Math.floor((mid.length - fftSize) / hop));
  const bins = fftSize / 2;
  const midMag = [];
  const sideMag = [];
  const re = new Float64Array(fftSize);
  const im = new Float64Array(fftSize);

  for (let f = 0; f < frames; f += 1) {
    for (const [src, out] of [[mid, midMag], [side, sideMag]]) {
      re.fill(0);
      im.fill(0);
      const base = f * hop;
      for (let i = 0; i < fftSize; i += 1) re[i] = src[base + i] * win[i];
      fft(re, im);
      const mag = new Float32Array(bins);
      for (let b = 0; b < bins; b += 1) mag[b] = Math.hypot(re[b], im[b]);
      out.push(mag);
    }
  }
  return { midMag, sideMag, binHz: rate / fftSize, hopMs, frames };
}

/** Sum magnitudes across a frequency range. */
function bandEnergy(mag, binHz, lowHz, highHz) {
  const from = Math.max(1, Math.floor(lowHz / binHz));
  const to = Math.min(mag.length - 1, Math.ceil(highHz / binHz));
  let sum = 0;
  for (let b = from; b <= to; b += 1) sum += mag[b];
  return sum;
}

module.exports = { bandEnergy, fft, spectrogram };
