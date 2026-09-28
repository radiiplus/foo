import { existsSync, mkdirSync, readdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const executable = process.platform === "win32" ? "nim.exe" : "nim";
const candidates = [process.env.NIM_BIN];
if (process.env.USERPROFILE) {
  const toolchains = join(process.env.USERPROFILE, ".choosenim", "toolchains");
  if (existsSync(toolchains)) {
    for (const version of readdirSync(toolchains).sort().reverse())
      candidates.push(join(toolchains, version, "bin", executable));
  }
}
candidates.push(executable);
const compiler = candidates.find(candidate =>
  candidate && (candidate === executable || existsSync(candidate))) ?? executable;
const artifacts = join(root, ".artifacts", "docs");
mkdirSync(artifacts, { recursive: true });
const output = join(artifacts, process.platform === "win32" ?
  "snippets.exe" : "snippets");
const args = ["c", "-r", "--nimcache:" + join(artifacts, "nimcache"),
  "--out:" + output];
if (process.platform === "win32") args.push("--cc:clang");
args.push(join(root, "test", "docs", "snippets.nim"));
const result = spawnSync(compiler, args,
  { cwd: root, stdio: "inherit", windowsHide: true });
if (result.error?.code === "ENOENT") {
  console.error("Nim is not installed. Install Nim or set NIM_BIN.");
  process.exit(1);
}
process.exit(result.status ?? 1);
