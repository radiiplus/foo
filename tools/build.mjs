import { option, value } from './arguments.mjs';
import { files } from './tree.mjs';
import { spawnSync as invoke } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync as chmod, cpSync as copy, existsSync as exists, mkdirSync as mkdir, readFileSync as read, realpathSync as realpath, rmSync as remove, statSync as stat, writeFileSync as write } from "node:fs";
import { resolve, join, dirname, basename, relative, isAbsolute, sep } from "node:path";
import { fileURLToPath as filename } from "node:url";

const root = resolve(dirname(filename(import.meta.url)), "..");
if (process.argv.includes("--help")) {
  console.log("Usage: node tools/build.mjs [--target TARGET] [--output DIRECTORY] [--native-root DIRECTORY | --native-bin FILE] [--rebuild] [--jobs N] [--mm orc|refc]");
  console.log("Builds and stages a distributable compiler for the host or supported cross-target.");
  process.exit(0);
}
const output = option("--output") || join(root, ".artifacts", "compiler");
function encloses(parent, child) {
  const path = relative(parent, child);
  return path === '' || path !== '..' && !path.startsWith('..' + sep) && !isAbsolute(path);
}
function canonical(path) {
  let ancestor = path;
  while (!exists(ancestor)) {
    const parent = dirname(ancestor);
    if (parent === ancestor) throw Error(`Cannot resolve release path: ${path}`);
    ancestor = parent;
  }
  return resolve(realpath(ancestor), relative(ancestor, path));
}
const destination = canonical(output);
const repository = canonical(root);
const protectedPaths = ["src", "lib", "vendor", "docs", "test", "benchmark",
  "tools", "bin", "installers", ".git", "node_modules", ".artifacts/vendor",
  ".artifacts/toolchain", ".artifacts/cache"].map(path => canonical(join(root, path)));
if (encloses(destination, repository) || protectedPaths.some(path =>
    encloses(path, destination) || encloses(destination, path)))
  throw Error(`Release output must be a dedicated directory outside project inputs: ${output}`);
const host = `${process.platform === "win32" ? "windows" : process.platform}-${process.arch}`;
const target = value("--target") || host;
const separator = target.lastIndexOf("-");
const system = target.slice(0, separator);
const architecture = target.slice(separator + 1);
const platform = system === "windows" ? "win32" : system;
const executable = platform === "win32" ? "foo.exe" : "foo";
const nativeBin = option("--native-bin");
if (nativeBin && (option("--native-root") || process.argv.includes("--rebuild")))
  throw Error("--native-bin cannot be combined with --native-root or --rebuild");
const directory = join(option("--native-root") || join(root, ".artifacts",
  process.argv.includes("--isolated") ? "release-native" : "native"), `${platform}-${architecture}`);
if (!nativeBin && (encloses(canonical(directory), destination) || encloses(destination, canonical(directory))))
  throw Error(`Release output must not overlap the native compiler build: ${output}`);
const binary = nativeBin || join(directory, executable);
if (nativeBin && encloses(destination, canonical(binary)))
  throw Error(`--native-bin must stay outside the release output: ${binary}`);
const audit = invoke(process.execPath, [join(root, "tools/vendor/audit.mjs")], { cwd: root, stdio: "inherit", windowsHide: true });
if (audit.status !== 0) process.exit(audit.status ?? 1);
if (nativeBin) {
  if (!exists(binary)) throw Error(`Native compiler was not found: ${binary}`);
  const expected = JSON.parse(read(join(root, "package.json"), "utf8")).version;
  const check = invoke(binary, ["version"], { encoding: "utf8", windowsHide: true });
  if (check.status !== 0 || !check.stdout?.split(/\r?\n/).some(line => line.trim() === `compiler ${expected}`))
    throw Error(`--native-bin must be a working FOO compiler ${expected}: ${binary}`);
} else {
  const native = invoke(process.execPath, [join(root, "tools/native.mjs"),
    ...(process.argv.includes("--rebuild") ? ["--rebuild"] : []),
    ...(value("--jobs") ? ["--jobs", value("--jobs")] : []),
    ...(value("--mm") ? ["--mm", value("--mm")] : []),
    "--target", target, "--output", binary, "--cache", join(directory, "nimcache")], {
    cwd: root,
    stdio: "inherit",
  });
  if (native.status !== 0) process.exit(native.status ?? 1);
}
remove(output, { recursive: true, force: true });
mkdir(join(output, "bin"), { recursive: true });
for (const name of ["assets", "lib", "docs", "vendor", "test/native/c/service.c", "test/native/c/vendor.c", "project.ivc", "README.md", "CHANGELOG.md", "LICENSE", "LICENSE-MIT", "LICENSE-APACHE"])
  copy(join(root, name), join(output, name), { recursive: true, dereference: name === "vendor",
    filter: source => !['.artifacts', '.foo', '.git', 'node_modules'].includes(basename(source)) });
if (platform === "linux") {
  const dependency = `linux-${architecture}`;
  const artifacts = join(root, ".artifacts", "vendor", dependency);
  if (!exists(join(artifacts, "provenance.json")))
    throw Error(`Release requires controlled ${dependency} dependency artifacts; explicitly run tools/vendor/build.mjs on that target first.`);
  copy(artifacts, join(output, ".artifacts", "vendor", dependency), { recursive: true });
}
const fixtures = files(join(root, "test", "library"), ".iv");
for (const source of fixtures) {
  const destination = join(output, relative(root, source));
  mkdir(dirname(destination), { recursive: true });
  copy(source, destination);
  if (!read(source).equals(read(destination)))
    throw Error(`Release fixture differs from its source: ${source}`);
}
for (const name of ["project.ivc", "public.txt"])
  copy(join(root, "test", "library", name), join(output, "test", "library", name));
for (const source of files(join(root, "benchmark", "algorithms"), ".iv")) {
  const destination = join(output, relative(root, source));
  mkdir(dirname(destination), { recursive: true });
  copy(source, destination);
}
for (const name of ["foo.mjs", "version.mjs"])
  copy(join(root, "bin", name), join(output, "bin", name));
if (platform === "win32") copy(join(root, "bin", "foo.cmd"), join(output, "bin", "foo.cmd"));
if (!exists(binary))
  throw new Error(`Native compiler was not produced: ${binary}`);
copy(binary, join(output, "bin", executable));
if (platform !== "win32") chmod(join(output, "bin", executable), 0o755);
const qbeName = platform === "win32" ? "qbe.exe" : "qbe";
const arm64Qbe = platform === "linux" && architecture === "arm64";
const qbeSource = (arm64Qbe ? process.env.FOO_QBE_ARM64 ||
  (process.arch === "arm64" ? process.env.FOO_QBE : "") : process.env.FOO_QBE) ||
  join(root, ".artifacts", "toolchain", "qbe", platform === "win32" ?
    "qbe-win.exe" : arm64Qbe ? "qbe-linux-arm64" : "qbe-linux");
if (!exists(qbeSource)) throw Error(`Release requires a ${architecture} QBE binary: ${qbeSource}`);
const qbeBinary = read(qbeSource);
if (platform === "win32" && qbeBinary.subarray(0, 2).toString("ascii") !== "MZ")
  throw Error(`Windows release requires a native Windows QBE executable: ${qbeSource}`);
if (platform === "linux") {
  const machine = arm64Qbe ? 183 : 62;
  if (qbeBinary.length < 20 || qbeBinary.toString("ascii", 1, 4) !== "ELF" ||
      qbeBinary[4] !== 2 || qbeBinary[5] !== 1 ||
      qbeBinary.readUInt16LE(18) !== machine)
    throw Error(`Linux ${architecture} release requires a matching QBE ELF executable: ${qbeSource}`);
}
copy(qbeSource, join(output, "bin", qbeName));
if (platform !== "win32") chmod(join(output, "bin", qbeName), 0o755);
const tccHome = process.env.FOO_TCC_HOME || join(root, ".artifacts", "toolchain", "tcc", "vendor-build", "source", "win32");
const tccAssets = platform === "win32" ? ["tcc.exe", "libtcc.dll", "include", "lib"] : [];
for (const name of tccAssets) {
  if (!exists(join(tccHome, name))) throw Error(`Windows release requires TinyCC asset: ${join(tccHome, name)}`);
  copy(join(tccHome, name), join(output, "bin", name), { recursive: true });
}
if (platform === "win32") copy(join(root, "tools", "tcc", "foo-winapi.def"),
  join(output, "bin", "lib", "foo-winapi.def"));
const arm64Bundle = platform === "linux" && architecture === "x64";
const x64Bundle = arm64Bundle;
const nativeArm64Bundle = platform === "linux" && architecture === "arm64";
const binutilsBundle = x64Bundle || platform === "win32" && architecture === "x64";
const x64TccHome = process.env.FOO_X64_TCC_HOME ||
  join(root, ".artifacts", "toolchain", "tcc", "linux-x64");
const x64MuslHome = process.env.FOO_X64_MUSL_HOME ||
  join(root, ".artifacts", "toolchain", "musl", "x64");
const assemblerHome = process.env.FOO_QBE_AS_HOME ||
  join(root, "vendor", "binutils", "linux-x64");
const assemblerNames = ["qbe-as", "qbe-as-arm64", "qbe-as-riscv64",
  "qbe-ld", "qbe-ld-arm64", "qbe-ld-riscv64",
  "libctf.so.0", "libctf-arm64.so.0", "libctf-riscv64.so.0",
  "libbfd-2.38-system.so", "libopcodes-2.38-system.so",
  "libbfd-2.38-arm64.so", "libopcodes-2.38-arm64.so",
  "libbfd-2.38-riscv64.so", "libopcodes-2.38-riscv64.so", "libz.so.1"];
if (binutilsBundle) {
  for (const name of assemblerNames) {
    const source = join(assemblerHome, name);
    if (!exists(source)) throw Error(`Linux x64 release requires assembler asset: ${source}`);
    copy(source, join(output, "bin", name));
  }
  for (const name of assemblerNames.filter(name => name.startsWith("qbe-as") ||
    name.startsWith("qbe-ld")))
    chmod(join(output, "bin", name), 0o755);
}
const x64Inputs = [
  [join(x64TccHome, "tcc"), join(output, "bin", "tcc")],
  [join(x64TccHome, "libtcc1.a"), join(output, "bin", "libtcc1.a")],
  [join(x64TccHome, "include", "stdatomic.h"),
    join(output, "bin", "include", "stdatomic.h")],
  [join(x64MuslHome, "usr", "include"), join(output, "vendor", "x64-musl", "include")],
  [join(x64MuslHome, "usr", "lib", "crt1.o"), join(output, "vendor", "x64-musl", "lib", "crt1.o")],
  [join(x64MuslHome, "usr", "lib", "libc.a"), join(output, "vendor", "x64-musl", "lib", "libc.a")],
];
if (x64Bundle) {
  for (const [source, target] of x64Inputs) {
    if (!exists(source)) throw Error(`Linux x64 release requires native asset: ${source}`);
    mkdir(dirname(target), { recursive: true });
    copy(source, target, { recursive: true });
  }
  chmod(join(output, "bin", "tcc"), 0o755);
}
const arm64TccHome = process.env.FOO_ARM64_TCC_HOME ||
  join(root, ".artifacts", "toolchain", "tcc", "linux-x64");
const arm64MuslHome = process.env.FOO_ARM64_MUSL_HOME ||
  join(root, ".artifacts", "toolchain", "musl", "arm64");
const arm64Inputs = [
  [join(arm64TccHome, "arm64-tcc"), join(output, "bin", "arm64-tcc")],
  [join(arm64TccHome, "arm64-libtcc1.a"), join(output, "bin", "arm64-libtcc1.a")],
  [join(arm64TccHome, "include", "stdatomic.h"),
    join(output, "bin", "include", "stdatomic.h")],
  [join(arm64MuslHome, "usr", "include"), join(output, "vendor", "arm64-musl", "include")],
  [join(arm64MuslHome, "usr", "lib", "crt1.o"), join(output, "vendor", "arm64-musl", "lib", "crt1.o")],
  [join(arm64MuslHome, "usr", "lib", "libc.a"), join(output, "vendor", "arm64-musl", "lib", "libc.a")],
];
const nativeArm64TccHome = process.env.FOO_NATIVE_ARM64_TCC_HOME ||
  join(root, ".artifacts", "toolchain", "tcc", "linux-arm64");
const nativeArm64AssemblerHome = process.env.FOO_NATIVE_ARM64_AS_HOME ||
  join(root, "vendor", "binutils", "linux-arm64");
const nativeArm64Inputs = [
  [join(nativeArm64TccHome, "arm64-tcc"), join(output, "bin", "arm64-tcc")],
  [join(arm64TccHome, "arm64-libtcc1.a"), join(output, "bin", "arm64-libtcc1.a")],
  [join(nativeArm64AssemblerHome, "qbe-as-arm64"), join(output, "bin", "qbe-as-arm64")],
  ...arm64Inputs.slice(2),
];
function requireArm64Elf(path) {
  const data = read(path);
  if (data.length < 20 || data.toString("ascii", 1, 4) !== "ELF" ||
      data[4] !== 2 || data[5] !== 1 || data.readUInt16LE(18) !== 183)
    throw Error(`Linux ARM64 release requires an AArch64 ELF executable: ${path}`);
}
if (arm64Bundle) {
  for (const [source, target] of arm64Inputs) {
    if (!exists(source)) throw Error(`Linux x64 release requires ARM64 asset: ${source}`);
    mkdir(dirname(target), { recursive: true });
    copy(source, target, { recursive: true });
  }
  chmod(join(output, "bin", "arm64-tcc"), 0o755);
}
if (nativeArm64Bundle) {
  for (const [source, target] of nativeArm64Inputs) {
    if (!exists(source)) throw Error(`Linux ARM64 release requires native asset: ${source}`);
    if (target.endsWith("arm64-tcc") || target.endsWith("qbe-as-arm64"))
      requireArm64Elf(source);
    mkdir(dirname(target), { recursive: true });
    copy(source, target, { recursive: true });
  }
  chmod(join(output, "bin", "arm64-tcc"), 0o755);
  chmod(join(output, "bin", "qbe-as-arm64"), 0o755);
}
function bytes(path) {
  const entry = stat(path);
  if (entry.isFile()) return entry.size;
  return files(path).reduce((sum, child) => sum + stat(child).size, 0);
}
const toolchainBytes = stat(binary).size + stat(qbeSource).size +
  tccAssets.reduce((sum, name) => sum + bytes(join(tccHome, name)), 0) +
  (x64Bundle ? x64Inputs.reduce((sum, [source]) => sum + bytes(source), 0) : 0) +
  (binutilsBundle ? assemblerNames.reduce((sum, name) => sum +
    bytes(join(assemblerHome, name)), 0) : 0) +
  (arm64Bundle ? arm64Inputs.reduce((sum, [source]) => sum + bytes(source), 0) : 0) +
  (nativeArm64Bundle ? nativeArm64Inputs.reduce((sum, [source]) => sum + bytes(source), 0) : 0);
const qbeLicense = join(root, "vendor", "qbe", "LICENSE");
const tccLicense = join(dirname(tccHome), "COPYING");
const arm64TccLicense = join(arm64TccHome, "COPYING");
const muslLicense = join(arm64MuslHome, "COPYRIGHT");
const x64TccLicense = join(x64TccHome, "COPYING");
const x64MuslLicense = join(x64MuslHome, "COPYRIGHT");
const assemblerLicense = join(assemblerHome, "COPYRIGHT");
const assemblerZlibLicense = join(assemblerHome, "ZLIB-COPYRIGHT");
const nativeArm64AssemblerLicense = join(nativeArm64AssemblerHome, "COPYRIGHT");
const nativeArm64TccLicense = join(nativeArm64TccHome, "COPYING");
for (const license of [qbeLicense, ...(platform === "win32" ? [tccLicense] : []),
  ...(x64Bundle ? [x64TccLicense, x64MuslLicense] : []),
  ...(binutilsBundle ? [assemblerLicense, assemblerZlibLicense] : []),
  ...(arm64Bundle ? [arm64TccLicense, muslLicense] : []),
  ...(nativeArm64Bundle ? [nativeArm64TccLicense, muslLicense,
    nativeArm64AssemblerLicense] : [])])
  if (!exists(license)) throw Error(`Toolchain license missing: ${license}`);
mkdir(join(output, "toolchain", "licenses"), { recursive: true });
copy(qbeLicense, join(output, "toolchain", "licenses", "QBE-LICENSE"));
if (platform === "win32") copy(tccLicense, join(output, "toolchain", "licenses", "TinyCC-COPYING"));
if (x64Bundle) {
  copy(x64TccLicense, join(output, "toolchain", "licenses", "TinyCC-x64-COPYING"));
  copy(x64MuslLicense, join(output, "toolchain", "licenses", "musl-x64-COPYRIGHT"));
}
if (binutilsBundle) {
  copy(assemblerLicense, join(output, "toolchain", "licenses", "Binutils-COPYRIGHT"));
  copy(assemblerZlibLicense, join(output, "toolchain", "licenses", "zlib-COPYRIGHT"));
}
if (arm64Bundle) {
  copy(arm64TccLicense, join(output, "toolchain", "licenses", "TinyCC-ARM64-COPYING"));
  copy(muslLicense, join(output, "toolchain", "licenses", "musl-COPYRIGHT"));
}
if (nativeArm64Bundle) {
  copy(nativeArm64TccLicense, join(output, "toolchain", "licenses", "TinyCC-ARM64-COPYING"));
  copy(muslLicense, join(output, "toolchain", "licenses", "musl-COPYRIGHT"));
  copy(nativeArm64AssemblerLicense,
    join(output, "toolchain", "licenses", "Binutils-ARM64-COPYRIGHT"));
}
const installedToolchainBytes = toolchainBytes + stat(qbeLicense).size +
  (platform === "win32" ? stat(tccLicense).size +
    stat(join(root, "tools", "tcc", "foo-winapi.def")).size : 0) +
  (x64Bundle ? stat(x64TccLicense).size + stat(x64MuslLicense).size : 0) +
  (binutilsBundle ? stat(assemblerLicense).size +
    stat(assemblerZlibLicense).size : 0) +
  (arm64Bundle ? stat(arm64TccLicense).size + stat(muslLicense).size : 0) +
  (nativeArm64Bundle ? stat(nativeArm64TccLicense).size + stat(muslLicense).size +
    stat(nativeArm64AssemblerLicense).size : 0);
if (installedToolchainBytes >= 55_000_000)
  throw Error(`Installed compiler toolchain exceeds 55 MB: ${installedToolchainBytes} bytes`);
const stagedAssets = [join(output, "bin", executable), join(output, "bin", qbeName),
  ...tccAssets.map(name => join(output, "bin", name)),
  ...(x64Bundle ? x64Inputs.map(([, target]) => target) : []),
  ...(binutilsBundle ? assemblerNames.map(name => join(output, "bin", name)) : []),
  ...(arm64Bundle ? arm64Inputs.map(([, target]) => target) : []),
  ...(nativeArm64Bundle ? nativeArm64Inputs.map(([, target]) => target) : []),
  join(output, "toolchain", "licenses")]
  .flatMap(path => stat(path).isDirectory() ? files(path) : [path]);
const receipts = stagedAssets.map(path => ({
  path: relative(output, path).replaceAll("\\", "/"),
  bytes: stat(path).size,
  sha256: createHash("sha256").update(read(path)).digest("hex"),
}));
const stagedBytes = receipts.reduce((sum, asset) => sum + asset.bytes, 0);
if (stagedBytes !== installedToolchainBytes)
  throw Error(`Staged toolchain size differs from its inputs: ${stagedBytes} vs ${installedToolchainBytes}`);
write(join(output, "toolchain", "installed.json"), JSON.stringify({
  format: "foo.toolchain.installation", version: 1, target,
  maximumUncompressedBytes: 55_000_000, uncompressedBytes: stagedBytes,
  assets: receipts,
}, null, 2) + "\n");
copy(join(root, "installers", "assets", "installer.ico"), join(output, "assets", "foo.ico"));
copy(join(root, "installers", "assets", "installer.png"), join(output, "assets", "foo.png"));
const binaries = { [platform]: `bin/${executable}` };
for (const script of ["arguments.mjs", "artifacts.mjs", "worker.mjs", "upgrade.mjs", "vendor/audit.mjs", "vendor/build.mjs", "vendor/verify.mjs", "runtime/audit.mjs"])
  copy(join(root, "tools", script), join(output, "tools", script));
mkdir(join(output, "toolchain"), { recursive: true });
copy(join(root, "toolchain", "assets.json"), join(output, "toolchain", "assets.json"));

const manifest = JSON.parse(read(join(root, "package.json"), "utf8"));
delete manifest.devDependencies;
delete manifest.dependencies;
manifest.files = ["assets", "bin", "lib", "docs", "vendor", "benchmark/algorithms/", "test/library/**/*.iv", "test/library/project.ivc",
  "test/library/public.txt", "test/native/c/service.c", "test/native/c/vendor.c", "tools/",
  "toolchain/assets.json", "toolchain/installed.json", "toolchain/licenses", "project.ivc", "README.md", "CHANGELOG.md", "LICENSE", "LICENSE-MIT",
  "LICENSE-APACHE", "foo.artifact.json", ".artifacts/vendor"];
manifest.scripts = { "vendor:audit": "node tools/vendor/audit.mjs", "vendor:build": "node tools/vendor/build.mjs" };
write(join(output, "package.json"), JSON.stringify(manifest, null, 2) + "\n");
write(join(output, "foo.artifact.json"), JSON.stringify({
  format: "foo.artifact",
  version: 1,
  language: "1",
  compiler: manifest.version,
  entry: "bin/foo.mjs",
  native: binaries[platform],
  binaries,
  platform,
  architecture: architecture,
  documentation: "docs/README.md",
  backend: "qbe",
  toolchain: { manifest: "toolchain/assets.json", installation: "toolchain/installed.json",
    bundled: ["bin/" + executable, "bin/" + qbeName,
    ...tccAssets.map(name => "bin/" + name),
    ...(x64Bundle ? ["bin/tcc", "bin/libtcc1.a", "bin/include/stdatomic.h",
      "vendor/x64-musl/include", "vendor/x64-musl/lib/crt1.o",
      "vendor/x64-musl/lib/libc.a"] : []),
    ...(binutilsBundle ? assemblerNames.map(name => "bin/" + name) : []),
    ...(arm64Bundle ? ["bin/arm64-tcc", "bin/arm64-libtcc1.a",
      "bin/include/stdatomic.h",
      "vendor/arm64-musl/include", "vendor/arm64-musl/lib/crt1.o",
      "vendor/arm64-musl/lib/libc.a"] : []),
    ...(nativeArm64Bundle ? ["bin/arm64-tcc", "bin/arm64-libtcc1.a",
      "bin/include/stdatomic.h", "bin/qbe-as-arm64", "vendor/arm64-musl/include",
      "vendor/arm64-musl/lib/crt1.o", "vendor/arm64-musl/lib/libc.a"] : [])],
    bytes: installedToolchainBytes,
    frontendBytes: stat(binary).size },
  files: manifest.files,
  dependencyManifest: "vendor/manifest.json",
  libraryFixtures: fixtures.map(source => relative(root, source).replaceAll("\\", "/")),
  runtimeRequirements: "bin/" + executable + ".dependencies.json",
}, null, 2) + "\n");
const inspection = invoke(process.execPath, [join(root, "tools/runtime/audit.mjs"), join(output, "bin", executable)], { cwd: root, stdio: "inherit", windowsHide: true });
if (inspection.status !== 0) process.exit(inspection.status ?? 1);
if (platform === "win32" && architecture === "x64") {
  const shared = invoke(process.execPath, [join(root, "tools/qbe/shared/verify.mjs"),
    "--compiler", join(output, "bin", executable),
    "--tcc", join(output, "bin", "tcc.exe"),
    "--output", join(root, ".artifacts", "qbe-shared-package")], {
    cwd: root, stdio: "inherit", windowsHide: true,
  });
  if (shared.status !== 0) process.exit(shared.status ?? 1);
}
console.log(`Built native FOO compiler: ${output}`);
