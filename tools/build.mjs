import { spawnSync } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { resolve, join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
function option(name) {
  const inline = process.argv.find(argument => argument.startsWith(`${name}=`));
  if (inline) {
    const value = inline.slice(name.length + 1);
    if (!value) throw Error(`${name} requires a value`);
    return resolve(value);
  }
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
if (process.argv.includes("--help")) {
  console.log("Usage: node tools/build.mjs [--target TARGET] [--output DIRECTORY]");
  console.log("Builds and stages a distributable compiler for the host or supported cross-target.");
  process.exit(0);
}
const output = option("--output") || join(root, ".artifacts", "compiler");
const host = `${process.platform === "win32" ? "windows" : process.platform}-${process.arch}`;
const target = value("--target") || host;
const separator = target.lastIndexOf("-");
const targetPlatform = target.slice(0, separator);
const targetArchitecture = target.slice(separator + 1);
const platform = targetPlatform === "windows" ? "win32" : targetPlatform;
const nativeName = platform === "win32" ? "foo.exe" : "foo";
const nativeDirectory = join(root, ".artifacts",
  process.argv.includes("--isolated") ? "release-native" : "native", `${platform}-${targetArchitecture}`);
const nativeSource = join(nativeDirectory, nativeName);
const native = spawnSync(process.execPath, [join(root, "tools/native.mjs"),
  "--target", target, "--output", nativeSource, "--cache", join(nativeDirectory, "nimcache")], {
  cwd: root,
  stdio: "inherit",
});
if (native.status !== 0) process.exit(native.status ?? 1);
rmSync(output, { recursive: true, force: true });
mkdirSync(join(output, "bin"), { recursive: true });
for (const name of ["assets", "std", "docs", "test/native/service.c", "toolchain.json", "project.json", "README.md", "CHANGELOG.md", "LICENSE", "LICENSE-MIT", "LICENSE-APACHE"])
  cpSync(join(root, name), join(output, name), { recursive: true });
for (const name of readdirSync(join(root, "test", "stdlib"))) {
  if (!name.endsWith(".iv") && !["project.json", "public.txt"].includes(name)) continue;
  cpSync(join(root, "test", "stdlib", name), join(output, "test", "stdlib", name));
}
for (const name of ["foo.mjs", "version.mjs"])
  cpSync(join(root, "bin", name), join(output, "bin", name));
if (platform === "win32") cpSync(join(root, "bin", "foo.cmd"), join(output, "bin", "foo.cmd"));
if (!existsSync(nativeSource))
  throw new Error(`Native compiler was not produced: ${nativeSource}`);
cpSync(nativeSource, join(output, "bin", nativeName));
if (platform !== "win32") chmodSync(join(output, "bin", nativeName), 0o755);
cpSync(join(root, "installers", "assets", "logo-installer.ico"), join(output, "assets", "foo.ico"));
cpSync(join(root, "installers", "assets", "logo-installer.png"), join(output, "assets", "foo.png"));
const binaries = { [platform]: `bin/${nativeName}` };
cpSync(join(root, "tools/toolchain.mjs"), join(output, "tools/toolchain.mjs"));

const manifest = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
delete manifest.devDependencies;
delete manifest.dependencies;
manifest.files = ["assets", "bin", "std", "docs", "test/stdlib/*.iv", "test/stdlib/project.json",
  "test/stdlib/public.txt", "test/native/service.c", "tools/toolchain.mjs",
  "toolchain.json", "project.json", "README.md", "CHANGELOG.md", "LICENSE", "LICENSE-MIT",
  "LICENSE-APACHE", "foo.artifact.json"];
manifest.scripts = { postinstall: "node tools/toolchain.mjs" };
writeFileSync(join(output, "package.json"), JSON.stringify(manifest, null, 2) + "\n");
writeFileSync(join(output, "foo.artifact.json"), JSON.stringify({
  format: "foo.artifact",
  version: 1,
  language: "1",
  compiler: manifest.version,
  entry: "bin/foo.mjs",
  native: binaries[platform],
  binaries,
  platform,
  architecture: targetArchitecture,
  documentation: "docs/README.md",
  backend: "0.16.0",
  files: manifest.files,
}, null, 2) + "\n");
console.log(`Built native FOO compiler: ${output}`);
