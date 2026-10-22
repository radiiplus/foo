import { value } from './arguments.mjs';
import { spawnSync as invoke } from "node:child_process";
import { existsSync as exists, mkdirSync as mkdir, readFileSync as read } from "node:fs";
import { arch } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath as filename } from "node:url";
import { checked, linux } from './wsl.mjs';

const root = resolve(dirname(filename(import.meta.url)), "..");


function architecture() {
  if (arch() === "x64") return "x64";
  if (arch() === "arm64") return "arm64";
  throw Error(`Unsupported Linux architecture: ${arch()}`);
}

function password() {
  const script = [
    '$secret = Read-Host "GPG passphrase" -AsSecureString',
    '$plain = [System.Net.NetworkCredential]::new("", $secret).Password',
    'if (-not $plain) { Write-Error "A passphrase is required"; exit 2 }',
    '[Console]::Out.Write($plain)',
  ].join("; ");
  const result = invoke("powershell.exe", ["-NoProfile", "-Command", script], {
    cwd: root,
    encoding: "utf8",
    stdio: ["inherit", "pipe", "inherit"],
    windowsHide: true,
  });
  if (result.status !== 0 || !result.stdout) throw Error("Unable to read the GPG passphrase");
  return result.stdout;
}

function build(platform, output) {
  console.log(`Building ${platform} -> ${output}`);
  const result = invoke(process.execPath, [join(root, "tools", "build.mjs"),
    "--isolated", "--target", platform, "--output", output], {
    cwd: root,
    stdio: "inherit",
  });
  if (result.status !== 0) {
    console.error(`${platform} build failed.`);
    process.exit(result.status ?? 1);
  }
}

function sign(binary, phrase) {
  const parameters = [join(root, "tools", "sign.mjs")];
  parameters.push(binary);
  const piped = phrase.length > 0;
  const result = invoke(process.execPath, parameters, {
    cwd: root,
    env: piped ? { ...process.env, FOOSIGNPIPE: "1" } : process.env,
    input: piped ? `${phrase}\n` : undefined,
    stdio: [piped ? "pipe" : "inherit", "inherit", "inherit"],
  });
  if (result.status !== 0) {
    console.error("Linux signing failed.");
    process.exit(result.status ?? 1);
  }
}

if (process.argv.includes("--help")) {
  console.log("Usage: node tools/binaries.mjs [--release DIR] [--sign] [--nowsl]");
  console.log("Windows builds Windows locally and Linux through WSL when available; Linux builds Linux only.");
  console.log("FOOSIGNER selects the GPG key when Linux signing is enabled.");
  process.exit(0);
}

const manifest = JSON.parse(read(join(root, "package.json"), "utf8"));
const directory = resolve(value("--release") ||
  join(root, "release", `foo-v${manifest.version}`));
const key = process.env.FOOSIGNER || "";
const signing = process.argv.includes("--sign") || key.length > 0;
const exclusive = process.argv.includes("--linux");
const skip = process.argv.includes("--nowsl");
const piped = process.env.FOOSIGNPIPE === "1";
let phrase = piped ? read(0, "utf8").replace(/\r?\n$/, "") : "";
mkdir(directory, { recursive: true });

if (process.platform === "linux") {
  const targets = architecture() === "x64" ? ["linux-x64", "linux-arm64"] : ["linux-arm64"];
  for (const target of targets) {
    const output = join(directory, `foo-v${manifest.version}-${target}`);
    build(target, output);
    const binary = join(output, "bin", "foo");
    if (!exists(binary)) throw Error(`Linux compiler was not produced: ${binary}`);
    if (signing) sign(binary, phrase);
    else console.log("Linux binary is unsigned. Set FOOSIGNER or pass --sign to require signing.");
    console.log(`Completed ${target}`);
  }
  process.exit(0);
}

if (process.platform !== "win32") {
  throw Error(`Unsupported build host '${process.platform}'. Run the Linux build on Linux.`);
}

if (exclusive) throw Error("--linux must run inside Linux or WSL");
const windows = arch() === "arm64" ? "windows-arm64" : "windows-x64";
build(windows, join(directory, `foo-v${manifest.version}-${windows}`));

if (skip) {
  console.log("Skipped WSL by request; only the Windows binary was built.");
  process.exit(0);
}

const script = linux(join(root, "tools", "binaries.mjs"));
const distribution = linux(directory);
if (signing) {
  phrase = password();
}
const [receipt] = checked([{ command: 'node',
  args: [script, '--linux', '--release', distribution, ...(signing ? ['--sign'] : [])],
  env: { ...(key ? { FOOSIGNER: key } : {}), ...(signing ? { FOOSIGNPIPE: '1' } : {}) },
  input: signing ? `${phrase}\n` : undefined,
  tools: ['clang', ...(signing ? ['gpg'] : [])], timeoutMs: 7200000,
  maxOutputBytes: 64 * 1024 * 1024 }]);
phrase = "";
process.stdout.write(receipt.stdout);
process.stderr.write(receipt.stderr);
console.log("Completed Windows and Linux compiler builds.");
