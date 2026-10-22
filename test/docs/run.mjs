import { find } from '../../tools/nim.mjs';
import { mkdirSync as mkdir } from "node:fs";
import { spawnSync as invoke } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath as filename } from "node:url";
import { environment, temporary } from '../location.mjs';

const root = resolve(dirname(filename(import.meta.url)), "../..");
const compiler = find();
const artifacts = temporary();
mkdir(artifacts, { recursive: true });
const output = join(artifacts, process.platform === "win32" ?
  "snippets.exe" : "snippets");
const args = ["c", "-r", "--nimcache:" + join(artifacts, "nimcache"),
  "--out:" + output];
if (process.platform === "win32") args.push("--cc:clang");
args.push(join(root, "test", "docs", "snippets.nim"));
const result = invoke(compiler, args,
  { cwd: root, env: environment(artifacts), stdio: "inherit", windowsHide: true });
if (result.error?.code === "ENOENT") {
  console.error("Nim is not installed. Install Nim or set NIM_BIN.");
  process.exit(1);
}
process.exit(result.status ?? 1);
