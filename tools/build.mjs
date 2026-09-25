import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { resolve, join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const output = join(root, ".artifacts", "compiler");
execFileSync(process.execPath, [join(root, "tools/native.mjs")], {
  cwd: root,
  stdio: "inherit",
});
rmSync(output, { recursive: true, force: true });
mkdirSync(join(output, "bin"), { recursive: true });
for (const name of ["assets", "std", "docs", "test/stdlib", "test/native/service.c", "toolchain.json", "project.json", "README.md", "CHANGELOG.md", "LICENSE", "LICENSE-MIT", "LICENSE-APACHE"])
  cpSync(join(root, name), join(output, name), { recursive: true });
rmSync(join(output, "test", "stdlib", ".artifacts"), { recursive: true, force: true });
for (const name of ["foo.mjs", "foo.cmd", "version.mjs"])
  cpSync(join(root, "bin", name), join(output, "bin", name));
const nativeName = process.platform === "win32" ? "foo.exe" : "foo";
const binaries = {};
for (const [platform, name] of [["win32", "foo.exe"], ["linux", "foo"]]) {
  const source = join(root, ".artifacts", "native", name);
  if (!existsSync(source)) continue;
  cpSync(source, join(output, "bin", name));
  binaries[platform] = `bin/${name}`;
}
if (!binaries[process.platform])
  throw new Error(`Native compiler was not produced: ${join(root, ".artifacts", "native", nativeName)}`);
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
  native: binaries[process.platform],
  binaries,
  platform: process.platform,
  architecture: process.arch,
  documentation: "docs/README.md",
  backend: "0.16.0",
  files: manifest.files,
}, null, 2) + "\n");
console.log(`Built native FOO compiler: ${output}`);
