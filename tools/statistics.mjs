export function median(values, upper = false) {
  if (!values.length || values.some(value => !Number.isFinite(value)))
    throw Error('Median requires nonempty finite samples');
  const ordered = [...values].sort((a, b) => a - b);
  const index = ordered.length >> 1;
  return upper || ordered.length % 2 ? ordered[index] : (ordered[index - 1] + ordered[index]) / 2;
}

export function summary(samples) {
  const ordered = [...samples].sort((a, b) => a - b);
  return {
    minimumMs: ordered[0], medianMs: median(ordered),
    meanMs: ordered.reduce((sum, value) => sum + value, 0) / ordered.length,
    percentile95Ms: ordered[Math.ceil(ordered.length * 0.95) - 1],
    maximumMs: ordered.at(-1), samplesMs: samples,
  };
}
