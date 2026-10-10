import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { delimiter, resolve, join, dirname } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
function option(name) {
  const index = process.argv.indexOf(name);
  if (index < 0) return "";
  const value = process.argv[index + 1];
  if (!value || value.startsWith("--")) throw Error(`${name} requires a value`);
  return resolve(value);
}
function value(name) {
  const inline = process.argv.find(argument => argument.startsWith(`${name}=`));
  if (inline) return inline.slice(name.length + 1);
  const index = process.argv.indexOf(name);
  if (index < 0) return "";
  const result = process.argv[index + 1];
  if (!result || result.startsWith("--")) throw Error(`${name} requires a value`);
  return result;
}
const executable = process.platform === "win32" ? "nim.exe" : "nim";
const candidates = [process.env.NIM_BIN];
const profile = process.env.USERPROFILE || homedir();
if (profile) {
  const toolchains = join(profile, ".choosenim", "toolchains");
  if (existsSync(toolchains)) {
    for (const version of readdirSync(toolchains).sort().reverse())
      candidates.push(join(toolchains, version, "bin", executable));
  }
}
// Let spawn resolve the regular executable after known absolute installations.
candidates.push(executable);
const compiler = candidates.find(candidate => candidate && (candidate === executable || existsSync(candidate))) ?? executable;
const output = option("--output") || join(root, ".artifacts", "native", process.platform === "win32" ? "foo.exe" : "foo");
const cache = option("--cache") || join(root, ".artifacts", "native", "nimcache");
const host = `${process.platform === "win32" ? "windows" : process.platform}-${process.arch}`;
const target = value("--target") || host;
if (process.argv.includes("--help")) {
  console.log("Usage: node tools/native.mjs [--check] [--target TARGET] [--output FILE] [--cache DIRECTORY]");
  console.log("Builds or checks the Nim compiler in src.");
  process.exit(0);
}
const crossArm = process.platform === "linux" && process.arch === "x64" && target === "linux-arm64";
if (target !== host && !crossArm) throw Error(`Cannot build ${target} from ${host}`);
const source = join(root, "src", "main.nim");
if (!existsSync(source)) throw Error("Missing src/main.nim");
mkdirSync(dirname(output), { recursive: true });
mkdirSync(cache, { recursive: true });
const embedded = [
  "package.json", "project.json",
  "assets/dark.svg", "installers/assets/installer.ico",
  "src/backend/native/service.c", "src/backend/native/service.h",
  "src/backend/native/vulkan.c",
  "src/backend/native/gpu.c",
  "src/backend/zig/library.zig", "src/backend/zig/storage.zig",
  "src/backend/zig/stream.zig", "src/backend/zig/service.zig",
  "src/backend/zig/shim.zig", "src/backend/c/runtime.h",
  "src/backend/c/arch.h", "src/backend/c/json.h", "src/backend/c/http.h",
  "src/backend/c/storage.h", "src/backend/c/stream.h",
  "src/backend/c/memory.c", "src/backend/c/trace.c", "src/backend/c/copy.c",
];
const embeddedDigest = createHash("sha256");
for (const name of embedded) {
  embeddedDigest.update(name);
  embeddedDigest.update("\0");
  embeddedDigest.update(readFileSync(join(root, name)));
  embeddedDigest.update("\0");
}
const digest = embeddedDigest.digest("hex");
const stamp = join(cache, "embedded.sha256");
const embeddedChanged = !existsSync(stamp) || readFileSync(stamp, "utf8").trim() !== digest;
const checking = process.argv.includes("--check");
const ssl = process.platform === "win32" ? [] : ["-d:ssl"];
const cross = crossArm ? ["--os:linux", "--cpu:arm64", "--cc:gcc",
  "--gcc.exe:aarch64-linux-gnu-gcc", "--gcc.linkerexe:aarch64-linux-gnu-gcc"] : [];
const args = checking
  ? ["check", ...ssl, ...cross, "--path:" + root, "--nimcache:" + cache, source]
  : ["c", "-d:release", ...ssl, ...cross, "--opt:size", "--nimcache:" + cache, "-o:" + output];
if (embeddedChanged) args.splice(1, 0, "-f");
if (!checking && process.platform === "win32") {
  const resource = join(cache, "foo.res");
  const resourceCompiler = process.env.LLVMRC || "llvm-rc.exe";
  const compiled = spawnSync(resourceCompiler, ["/FO", resource, join(root, "installers", "windows", "foo.rc")], {
    cwd: join(root, "installers", "windows"),
    stdio: "inherit",
    windowsHide: true,
  });
  if (compiled.error?.code === "ENOENT") {
    console.error("llvm-rc is required to embed the FOO icon. Install LLVM or set LLVMRC to llvm-rc.exe.");
    process.exit(1);
  }
  if (compiled.status !== 0) process.exit(compiled.status ?? 1);
  args.push("--cc:clang", "--passL:" + resource);
}
if (!checking) args.push(source);
let environment = process.env;
if (crossArm) {
  const toolchain = JSON.parse(readFileSync(join(root, "toolchain.json"), "utf8"));
  const zig = join(root, ".artifacts", "toolchain", toolchain.zig, "zig");
  if (!existsSync(zig)) throw Error("Managed Zig is required for the Linux ARM64 cross-build. Run node tools/toolchain.mjs first.");
  const crossDirectory = join(root, ".artifacts", "cross");
  const wrapper = join(crossDirectory, "aarch64-linux-gnu-gcc");
  mkdirSync(crossDirectory, { recursive: true });
  writeFileSync(wrapper, "#!/bin/sh\nset -eu\nscript_dir=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)\nexec \"$script_dir/../toolchain/" + toolchain.zig + "/zig\" cc -target aarch64-linux-gnu.2.27 \"$@\"\n");
  chmodSync(wrapper, 0o755);
  environment = { ...process.env, PATH: crossDirectory + delimiter + (process.env.PATH || "") };
}
const result = spawnSync(compiler, args, { cwd: root, env: environment, stdio: "inherit", windowsHide: true });
if (result.error?.code === "ENOENT") {
  const location = process.platform === "linux" ? " inside Linux or WSL" : "";
  console.error(`Nim 2.2.12 is not installed${location}. Install it there, then rerun the build.`);
  process.exit(1);
}
if (result.status !== 0) process.exit(result.status ?? 1);
if (!checking) writeFileSync(stamp, digest + "\n");
console.log(checking ? "Nim compiler check passed." : `Built native FOO compiler: ${output}`);
