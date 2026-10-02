import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { arch } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function value(name) {
  const inline = process.argv.find(argument => argument.startsWith(`${name}=`));
  if (inline) {
    const result = inline.slice(name.length + 1);
    if (!result) throw Error(`${name} requires a value`);
    return result;
  }
  const index = process.argv.indexOf(name);
  if (index < 0) return "";
  const result = process.argv[index + 1];
  if (!result || result.startsWith("--")) throw Error(`${name} requires a value`);
  return result;
}

function linuxArchitecture() {
  if (arch() === "x64") return "x64";
  if (arch() === "arm64") return "arm64";
  throw Error(`Unsupported Linux architecture: ${arch()}`);
}

function wslPath(path) {
  const absolute = resolve(path);
  const match = /^([A-Za-z]):[\\/](.*)$/.exec(absolute);
  if (!match) throw Error(`WSL builds require a local Windows drive path: ${absolute}`);
  return `/mnt/${match[1].toLowerCase()}/${match[2].replaceAll("\\", "/")}`;
}

function password() {
  const script = [
    '$secret = Read-Host "GPG passphrase" -AsSecureString',
    '$plain = [System.Net.NetworkCredential]::new("", $secret).Password',
    'if (-not $plain) { Write-Error "A passphrase is required"; exit 2 }',
    '[Console]::Out.Write($plain)',
  ].join("; ");
  const result = spawnSync("powershell.exe", ["-NoProfile", "-Command", script], {
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
  const result = spawnSync(process.execPath, [join(root, "tools", "build.mjs"),
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
  const result = spawnSync(process.execPath, parameters, {
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

const manifest = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
const releaseDirectory = resolve(value("--release") ||
  join(root, "release", `foo-v${manifest.version}`));
const key = process.env.FOOSIGNER || "";
const distro = process.env.FOOWSL || "Ubuntu-22.04";
const signing = process.argv.includes("--sign") || key.length > 0;
const linuxOnly = process.argv.includes("--linux");
const skipWsl = process.argv.includes("--nowsl");
const piped = process.env.FOOSIGNPIPE === "1";
let phrase = piped ? readFileSync(0, "utf8").replace(/\r?\n$/, "") : "";
mkdirSync(releaseDirectory, { recursive: true });

if (process.platform === "linux") {
  const targets = linuxArchitecture() === "x64" ? ["linux-x64", "linux-arm64"] : ["linux-arm64"];
  for (const target of targets) {
    const output = join(releaseDirectory, `foo-v${manifest.version}-${target}`);
    build(target, output);
    const binary = join(output, "bin", "foo");
    if (!existsSync(binary)) throw Error(`Linux compiler was not produced: ${binary}`);
    if (signing) sign(binary, phrase);
    else console.log("Linux binary is unsigned. Set FOOSIGNER or pass --sign to require signing.");
    console.log(`Completed ${target}`);
  }
  process.exit(0);
}

if (process.platform !== "win32") {
  throw Error(`Unsupported build host '${process.platform}'. Run the Linux build on Linux.`);
}

if (linuxOnly) throw Error("--linux must run inside Linux or WSL");
const windowsTarget = arch() === "arm64" ? "windows-arm64" : "windows-x64";
build(windowsTarget, join(releaseDirectory, `foo-v${manifest.version}-${windowsTarget}`));

if (skipWsl) {
  console.log("Skipped WSL by request; only the Windows binary was built.");
  process.exit(0);
}

const wsl = spawnSync("wsl.exe", ["-d", distro, "--", "true"], { windowsHide: true });
if (wsl.error?.code === "ENOENT" || wsl.status !== 0) {
  console.warn(`WSL is not installed or Linux distribution ${distro} is not ready.`);
  console.warn("Install it from an elevated PowerShell terminal with:");
  console.warn("  wsl --install -d Ubuntu-22.04");
  console.warn("The Windows binary was built; rerun this command after WSL setup to add Linux.");
  process.exit(0);
}

const script = wslPath(join(root, "tools", "binaries.mjs"));
const linuxRelease = wslPath(releaseDirectory);
const parameters = ["-d", distro, "--"];
if (key || signing) parameters.push("env");
if (key) parameters.push(`FOOSIGNER=${key}`);
if (signing) {
  phrase = password();
  parameters.push("FOOSIGNPIPE=1");
}
parameters.push("node", script, "--linux", "--release", linuxRelease);
if (signing) parameters.push("--sign");
const linux = spawnSync("wsl.exe", parameters, {
  cwd: root,
  input: signing ? `${phrase}\n` : undefined,
  stdio: [signing ? "pipe" : "inherit", "inherit", "inherit"],
  windowsHide: true,
});
phrase = "";
if (linux.error?.code === "ENOENT") throw Error("WSL disappeared while starting the Linux build");
if (linux.status !== 0) {
  console.error("The WSL Linux build failed. Ensure Node, Nim 2.2.12, Clang, and GPG are installed inside WSL.");
  process.exit(linux.status ?? 1);
}
console.log("Completed Windows and Linux compiler builds.");
