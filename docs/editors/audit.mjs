// Phase 0 audit tooling only; this does not register an editor or a language.
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = dirname(fileURLToPath(import.meta.url));
const cache = resolve(directory, '../../.tratio/editor-audit');
mkdirSync(cache, { recursive: true });
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const repositories = [
  ['wix-incubator/react-templates', 'React Templates'],
  ['magalhaesm/42-cursus-miniRT', 'miniRT scenes'],
  ['Aprilistic/miniRT', 'miniRT scenes'],
  ['radiiplus/tratio', 'Tratio'],
  ['contact-discovery/rt_phone_numbers', 'Rainbow tables'],
  ['SubtitleEdit/subtitleedit', 'RealText subtitles'],
];
export const candidates = [
  { name: 'module', flags: 'm', pattern: String.raw`^[ \t]*module[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t\r\n]*\{` },
  { name: 'phrases', flags: '', pattern: String.raw`\b(?:give(?:[ \t]+[^.\r\n]*)?[ \t]*\.|(?:constant|mutable)[ \t]+[A-Za-z_][A-Za-z0-9_]*[^.\r\n]*\bis\b|function[ \t]+[A-Za-z_][A-Za-z0-9_]*[^{}\r\n]*\bof[ \t]+type\b|use[ \t]+c[ \t]+"[^"\r\n]+")` },
  { name: 'combined', flags: '', pattern: String.raw`^(?:[ \t\r\n]|---[\s\S]*?---|--[^\r\n]*(?:\r?\n|$))*module[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t\r\n]*\{(?=[\s\S]*\b(?:give(?:[ \t]+[^.\r\n]*)?[ \t]*\.|function[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*(?:\[[^\]\r\n]+\][ \t]*)?\(|type[ \t]+[A-Za-z_][A-Za-z0-9_]*[^.\r\n]*\bis\b|(?:constant|mutable)[ \t]+[A-Za-z_][A-Za-z0-9_]*[^.\r\n]*\bis\b|use[ \t]+(?:c[ \t]+)?"[^"\r\n]+"|start[ \t]*\([ \t]*\)))` },
];
const match = bytes => {
  // Match only a bounded UTF-8 prefix; binary/invalid UTF-8 input abstains.
  let text;
  try { text = new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, 65536)); } catch { return candidates.map(() => false); }
  if (text.includes('\0')) return candidates.map(() => false);
  text = text.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n');
  return candidates.map(c => new RegExp(c.pattern, c.flags).test(text));
};

async function read(url) {
  const file = join(cache, hash(url));
  if (existsSync(file) && !(process.argv.includes('--refresh') && url.includes('/git/trees/HEAD'))) return readFileSync(file);
  const response = await fetch(url, { headers: { 'User-Agent': 'Tratio-Naming-Audit', Accept: 'application/vnd.github+json' }, signal: AbortSignal.timeout(60000) });
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${url}`);
  const bytes = Buffer.from(await response.arrayBuffer());
  writeFileSync(file, bytes);
  return bytes;
}
async function map(values, work, limit = 6) {
  const results = new Array(values.length); let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, values.length) }, async () => {
    while (next < values.length) { const index = next++; results[index] = await work(values[index]); }
  }));
  return results;
}

if (process.argv.includes('--verify')) {
  const saved = JSON.parse(readFileSync(join(directory, 'evidence.json'), 'utf8'));
  if (JSON.stringify(saved.candidates) !== JSON.stringify(candidates)) throw new Error('Candidate definitions changed; rerun the audit.');
  for (const file of saved.files) {
    const bytes = await read(file.url);
    const blob = createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
    if (blob !== file.blob || hash(bytes) !== file.sha256 || JSON.stringify(match(bytes)) !== JSON.stringify(file.matches)) throw new Error(`Evidence mismatch: ${file.url}`);
  }
  for (const [index, metric] of saved.metrics.entries()) {
    const count = (positive, hit) => saved.files.filter(file => file.positive === positive && file.matches[index] === hit).length;
    if (metric.tp !== count(true, true) || metric.fp !== count(false, true) || metric.tn !== count(false, false) || metric.fn !== count(true, false)) throw new Error(`Metric mismatch: ${metric.candidate}`);
  }
  console.log(`Verified ${saved.files.length} pinned files and ${saved.metrics.length} candidate results.`);
  process.exit(0);
}
const evidence = { date: new Date().toISOString(), prefixBytes: 65536, candidates, searches: [], inventories: [], files: [], skipped: [], failures: [] };
for (const query of ['extension:rt', 'extension:rt "rt-if"', 'extension:rt "module"', 'extension:rt "<window"']) {
  const url = `https://api.github.com/search/code?q=${encodeURIComponent(query)}&per_page=100`;
  try {
    const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
    const response = await fetch(url, { headers: { 'User-Agent': 'Tratio-Naming-Audit', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, signal: AbortSignal.timeout(15000) });
    const body = await response.json();
    evidence.searches.push({ query, url, status: response.status, total: body.total_count ?? null, message: body.message ?? null });
  } catch (error) { evidence.searches.push({ query, url, status: null, total: null, message: error.message }); }
}
const inventories = await map(repositories, async ([repo, family]) => {
  try {
    const url = `https://api.github.com/repos/${repo}/git/trees/HEAD?recursive=1`;
    const tree = JSON.parse((await read(url)).toString('utf8'));
    if (tree.truncated) throw new Error(`Truncated tree: ${repo}`);
    const paths = tree.tree.filter(row => row.type === 'blob' && row.path.endsWith('.rt'));
    const selected = paths.filter(row => family !== 'Tratio' || row.path.startsWith('std/')).sort((a, b) => hash(a.path).localeCompare(hash(b.path))).slice(0, 40);
    const inventory = { repo, family, tree: tree.sha, url, count: paths.length, selected: selected.length, paths: paths.map(row => ({ path: row.path, sha: row.sha, size: row.size })) };
    console.log(`${repo}: ${paths.length} .rt files; selected ${selected.length}`);
    return { inventory, selected };
  } catch (error) { evidence.failures.push({ repo, error: error.message }); console.log(error.message); }
}, 3);
for (const result of inventories.filter(Boolean)) {
  const { inventory, selected } = result; evidence.inventories.push(inventory);
  const files = await map(selected, async row => {
    const url = `https://raw.githubusercontent.com/${inventory.repo}/${inventory.tree}/${row.path}`;
    if (row.size > 1048576) {
      evidence.skipped.push({ repo: inventory.repo, path: row.path, url, bytes: row.size, reason: 'Exceeds 1 MiB audit download limit; inventoried but not classified.' });
      return;
    }
    try {
      const bytes = await read(url);
      const blob = createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
      if (blob !== row.sha) throw new Error(`Blob differs from inventory: ${url}`);
      const first = bytes.toString('utf8').split(/\r?\n/).find(line => line.trim()) || '';
      return { repo: inventory.repo, family: inventory.family, positive: inventory.family === 'Tratio', path: row.path, url, blob, sha256: hash(bytes), bytes: bytes.length, snippet: first.split(/\s+/).slice(0, 20).join(' ').slice(0, 160), matches: match(bytes) };
    } catch (error) { evidence.failures.push({ url, error: error.message }); }
  });
  evidence.files.push(...files.filter(Boolean));
}
evidence.metrics = candidates.map((candidate, index) => {
  const count = (positive, hit) => evidence.files.filter(file => file.positive === positive && file.matches[index] === hit).length;
  const tp = count(true, true), fp = count(false, true), tn = count(false, false), fn = count(true, false);
  return { candidate: candidate.name, tp, fp, tn, fn, precision: tp + fp ? tp / (tp + fp) : null, recall: tp + fn ? tp / (tp + fn) : null };
});
const unique = [...new Map(evidence.files.map(file => [file.sha256, file])).values()];
evidence.unique = { files: unique.length, positive: unique.filter(file => file.positive).length, negative: unique.filter(file => !file.positive).length, metrics: candidates.map((candidate, index) => {
  const count = (positive, hit) => unique.filter(file => file.positive === positive && file.matches[index] === hit).length;
  const tp = count(true, true), fp = count(false, true), tn = count(false, false), fn = count(true, false);
  return { candidate: candidate.name, tp, fp, tn, fn, precision: tp + fp ? tp / (tp + fp) : null, recall: tp + fn ? tp / (tp + fn) : null };
}) };
writeFileSync(join(directory, 'evidence.json'), JSON.stringify(evidence, null, 2) + '\n');
console.log(JSON.stringify({ metrics: evidence.metrics, failures: evidence.failures.length, files: evidence.files.length }));
