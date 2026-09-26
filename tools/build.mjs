import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
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
for (const name of ["assets", "std", "docs", "test/native/service.c", "toolchain.json", "project.json", "README.md", "CHANGELOG.md", "LICENSE", "LICENSE-MIT", "LICENSE-APACHE"])
  cpSync(join(root, name), join(output, name), { recursive: true });
for (const name of readdirSync(join(root, "test", "stdlib"))) {
  if (!name.endsWith(".iv") && !["project.json", "public.txt"].includes(name)) continue;
  cpSync(join(root, "test", "stdlib", name), join(output, "test", "stdlib", name));
}
for (const name of ["foo.mjs", "foo.cmd", "version.mjs"])
  cpSync(join(root, "bin", name), join(output, "bin", name));
const nativeName = process.platform === "win32" ? "foo.exe" : "foo";
const nativeSource = join(root, ".artifacts", "native", nativeName);
if (!existsSync(nativeSource))
  throw new Error(`Native compiler was not produced: ${nativeSource}`);
cpSync(nativeSource, join(output, "bin", nativeName));
const binaries = { [process.platform]: `bin/${nativeName}` };
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
