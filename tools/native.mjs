import { existsSync, mkdirSync, readdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const executable = process.platform === "win32" ? "nim.exe" : "nim";
const candidates = [process.env.NIM_BIN];
if (process.env.USERPROFILE) {
  const toolchains = join(process.env.USERPROFILE, ".choosenim", "toolchains");
  if (existsSync(toolchains)) {
    for (const version of readdirSync(toolchains).sort().reverse())
      candidates.push(join(toolchains, version, "bin", executable));
  }
}
// Let spawn resolve the regular executable after known absolute installations.
candidates.push(executable);
const compiler = candidates.find(candidate => candidate && (candidate === executable || existsSync(candidate))) ?? executable;
const output = join(root, ".artifacts", "native", process.platform === "win32" ? "foo.exe" : "foo");
const cache = join(root, ".artifacts", "native", "nimcache");
if (process.argv.includes("--help")) {
  console.log("Usage: npm run native:build | npm run check");
  console.log("Builds or checks the Nim compiler in src.");
  process.exit(0);
}
const source = join(root, "src", "main.nim");
if (!existsSync(source)) throw Error("Missing src/main.nim");
mkdirSync(join(root, ".artifacts", "native"), { recursive: true });
mkdirSync(cache, { recursive: true });
const checking = process.argv.includes("--check");
const args = checking
  ? ["check", "--path:" + root, "--nimcache:" + cache, source]
  : ["c", "-d:release", "--opt:size", "--nimcache:" + cache, "-o:" + output];
if (!checking && process.platform === "win32") args.push("--cc:clang");
if (!checking) args.push(source);
const result = spawnSync(compiler, args, { cwd: root, stdio: "inherit", windowsHide: true });
if (result.error?.code === "ENOENT") {
  console.error("Nim is not installed. Install Nim, then run npm run native:build again.");
  process.exit(1);
}
if (result.status !== 0) process.exit(result.status ?? 1);
console.log(checking ? "Nim compiler check passed." : `Built native FOO compiler: ${output}`);
