import { find } from './nim.mjs';
import { option, value } from './arguments.mjs';
import { chmodSync as chmod, existsSync as exists, mkdirSync as mkdir, readFileSync as read, writeFileSync as write } from "node:fs";
import { createHash as hasher } from "node:crypto";
import { spawnSync as invoke } from "node:child_process";
import { delimiter, resolve, join, dirname } from "node:path";
import { availableParallelism as concurrency, totalmem } from "node:os";
import { fileURLToPath as filename } from "node:url";
import { embedded, compile } from "./inputs.mjs";
import { detect as managed } from "./toolchain.mjs";

const root = resolve(filename(new URL("..", import.meta.url)));
const compiler = find();
const output = option("--output") || join(root, ".artifacts", "native", process.platform === "win32" ? "foo.exe" : "foo");
const cache = option("--cache") || join(root, ".artifacts", "native", "nimcache");
const host = `${process.platform === "win32" ? "windows" : process.platform}-${process.arch}`;
const target = value("--target") || host;
const manager = value("--mm") || "orc";
if (!["orc", "refc"].includes(manager)) throw Error("--mm must be orc or refc");
if (process.argv.includes("--help")) {
  console.log("Usage: node tools/native.mjs [--check] [--rebuild] [--jobs N] [--target TARGET] [--output FILE] [--cache DIRECTORY] [--mm orc|refc]");
  console.log("Builds or checks the Nim compiler in src.");
  process.exit(0);
}
const foreign = process.platform === "linux" && process.arch === "x64" && target === "linux-arm64";
if (target !== host && !foreign) throw Error(`Cannot build ${target} from ${host}`);
const source = join(root, "src", "main.nim");
if (!exists(source)) throw Error("Missing src/main.nim");
mkdir(dirname(output), { recursive: true });
mkdir(cache, { recursive: true });
const inputs = embedded(root);
const fingerprint = hasher("sha256");
fingerprint.update(`memory-manager:${manager}\0`);
for (const name of inputs) {
  fingerprint.update(name);
  fingerprint.update("\0");
  fingerprint.update(read(name));
  fingerprint.update("\0");
}
const digest = fingerprint.digest("hex");
const stamp = join(cache, "embedded.sha256");
const changed = !exists(stamp) || read(stamp, "utf8").trim() !== digest;
const checking = process.argv.includes("--check");
const ssl = process.platform === "win32" ? [] : ["-d:ssl"];
const cross = foreign ? ["--os:linux", "--cpu:arm64", "--cc:gcc",
  "--gcc.exe:aarch64-linux-gnu-gcc", "--gcc.linkerexe:aarch64-linux-gnu-gcc"] : [];
const args = checking
  ? ["check", ...ssl, ...cross, "--path:" + root, "--nimcache:" + cache]
  : ["c", "-d:release", ...ssl, ...cross, "--opt:size", "--nimcache:" + cache, "-o:" + output];
args.push(`--mm:${manager}`);
const requested = Number(value("--jobs") || process.env.FOO_BUILD_JOBS || 2);
if (!Number.isInteger(requested) || requested < 1) throw Error('--jobs must be a positive integer');
const jobs = Math.min(requested, 4, Math.max(1, concurrency() - 1), Math.max(1, Math.floor(totalmem() / (2 * 1024 ** 3))));
if (!checking) args.push(`--parallelBuild:${jobs}`);
// Imported staticRead constants can survive incremental Nim compilation.
// Rebuild the compiler when an embedded input changes so its runtime identity is exact.
if (process.argv.includes("--rebuild") || changed) args.splice(1, 0, "-f");
if (changed) console.log(`Embedded inputs changed (${inputs.length} files); regenerating affected Nim modules.`);
if (!checking && process.platform === "win32") {
  const { resource, hit } = compile({ root, cache, force: process.argv.includes("--rebuild") });
  console.log(`Windows resource: ${hit ? "content hit" : "compiled"}.`);
  args.push("--cc:clang", "--passL:" + resource);
}
args.push(source);
let environment = process.env;
if (foreign) {
  const toolchain = managed();
  if (!toolchain) throw Error("Managed Zig is required for the Linux ARM64 cross-build. Run node tools/toolchain.mjs first.");
  const directory = join(root, ".artifacts", "cross");
  const wrapper = join(directory, "aarch64-linux-gnu-gcc");
  mkdir(directory, { recursive: true });
  const compilerPath = "'" + toolchain.path.replaceAll("'", "'\\''") + "'";
  write(wrapper, "#!/bin/sh\nset -eu\nexec " + compilerPath + " cc -target aarch64-linux-gnu.2.27 \"$@\"\n");
  chmod(wrapper, 0o755);
  environment = { ...process.env, PATH: directory + delimiter + (process.env.PATH || "") };
}
const result = invoke(compiler, args, { cwd: root, env: environment, stdio: "inherit", windowsHide: true });
if (result.error?.code === "ENOENT") {
  const location = process.platform === "linux" ? " inside Linux or WSL" : "";
  console.error(`Nim 2.2.12 is not installed${location}. Install it there, then rerun the build.`);
  process.exit(1);
}
if (result.status !== 0) process.exit(result.status ?? 1);
if (!checking) write(stamp, digest + "\n");
console.log(checking ? "Nim compiler check passed." : `Built native FOO compiler: ${output}`);
