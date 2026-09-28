import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const settings = resolve(process.env.FOOSIGNENV || join(root, ".env.sign"));
if (!existsSync(settings)) {
  throw Error("Create .env.sign from .env.sign.example and set FOOSIGNEMAIL");
}
process.loadEnvFile(settings);

const allowed = new Set(["--help", "--preview", "--dry-run", "--unprotected"]);
for (const argument of process.argv.slice(2)) {
  if (!allowed.has(argument)) throw Error(`Unknown option ${argument}; configure signing through .env.sign`);
}

const distro = process.env.FOOWSL || "Ubuntu-22.04";
const gpg = process.env.FOOGPG || "gpg";
const home = process.env.FOOGPGHOME || "";

function prepare() {
  if (!home) return;
  if (process.platform === "win32") {
    const result = spawnSync("wsl.exe", ["-d", distro, "--", "mkdir", "-p", "-m", "700", "--", home], {
      cwd: root,
      stdio: "inherit",
      windowsHide: true,
    });
    if (result.status !== 0) throw Error(`Unable to create GPG home ${home}`);
    return;
  }
  mkdirSync(home, { recursive: true, mode: 0o700 });
}

function run(parameters, capture = false, allow = [], input) {
  const command = process.platform === "win32" ? "wsl.exe" : gpg;
  const options = home ? ["--homedir", home, ...parameters] : parameters;
  const args = process.platform === "win32" ? ["-d", distro, "--", gpg, ...options] : options;
  const piped = input !== undefined;
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: capture ? "utf8" : undefined,
    input,
    stdio: capture
      ? [piped ? "pipe" : "inherit", "pipe", "pipe"]
      : [piped ? "pipe" : "inherit", "inherit", "inherit"],
    windowsHide: true,
  });
  if (result.error?.code === "ENOENT") {
    const location = process.platform === "win32" ? ` in WSL distribution ${distro}` : "";
    throw Error(`GPG is required${location}`);
  }
  if (result.status !== 0 && !allow.includes(result.status)) {
    const detail = capture ? result.stderr.trim() : "";
    throw Error(detail || `GPG exited with status ${result.status ?? "unknown"}`);
  }
  return capture ? result.stdout : "";
}

function password() {
  if (process.platform === "win32") {
    const script = [
      '$first = Read-Host "GPG passphrase" -AsSecureString',
      '$second = Read-Host "Confirm passphrase" -AsSecureString',
      '$left = [System.Net.NetworkCredential]::new("", $first).Password',
      '$right = [System.Net.NetworkCredential]::new("", $second).Password',
      'if ($left.Length -lt 12) { Write-Error "Use at least 12 characters"; exit 2 }',
      'if ($left -cne $right) { Write-Error "Passphrases do not match"; exit 3 }',
      '[Console]::Out.Write($left)',
    ].join("; ");
    const result = spawnSync("powershell.exe", ["-NoProfile", "-Command", script], {
      cwd: root,
      encoding: "utf8",
      stdio: ["inherit", "pipe", "inherit"],
      windowsHide: true,
    });
    if (result.status !== 0 || !result.stdout) throw Error("Unable to read a protected GPG passphrase");
    return result.stdout;
  }

  const script = [
    'set -eu',
    'trap \'stty echo </dev/tty 2>/dev/null || true\' EXIT',
    'printf "GPG passphrase: " >/dev/tty',
    'IFS= read -r -s first </dev/tty',
    'printf "\\nConfirm passphrase: " >/dev/tty',
    'IFS= read -r -s second </dev/tty',
    'printf "\\n" >/dev/tty',
    '[ "${#first}" -ge 12 ] || { echo "Use at least 12 characters" >/dev/tty; exit 2; }',
    '[ "$first" = "$second" ] || { echo "Passphrases do not match" >/dev/tty; exit 3; }',
    'printf %s "$first"',
  ].join("; ");
  const result = spawnSync("bash", ["-c", script], {
    cwd: root,
    encoding: "utf8",
    stdio: ["inherit", "pipe", "inherit"],
  });
  if (result.status !== 0 || !result.stdout) throw Error("Unable to read a protected GPG passphrase");
  return result.stdout;
}

function fingerprint(identity) {
  const listing = run(["--batch", "--with-colons", "--list-secret-keys", identity], true, [2]);
  let secret = false;
  for (const line of listing.split(/\r?\n/)) {
    const fields = line.split(":");
    if (fields[0] === "sec") secret = true;
    else if (secret && fields[0] === "fpr") return fields[9] || "";
  }
  return "";
}

function save(key) {
  const line = `FOOSIGNKEY=${key}`;
  const source = readFileSync(settings, "utf8");
  const updated = /^FOOSIGNKEY=.*$/m.test(source)
    ? source.replace(/^FOOSIGNKEY=.*$/m, line)
    : `${source.trimEnd()}\n${line}\n`;
  writeFileSync(settings, updated);
}

if (process.argv.includes("--help")) {
  console.log("Usage: node tools/key.mjs [--unprotected] [--preview]");
  console.log("Creates or reuses a GPG Ed25519 release-signing key, updates .env.sign, and exports public and private backups.");
  console.log("Configure FOOSIGNEMAIL and related FOOSIGN* values in .env.sign before running this command.");
  console.log("Protected keys use GPG's secure passphrase prompt. --unprotected is intended only for disposable automation.");
  process.exit(0);
}

prepare();

const name = process.env.FOOSIGNNAME || "FOO Releases";
const email = process.env.FOOSIGNEMAIL || "";
const expires = process.env.FOOSIGNEXPIRES || "2y";
const manifest = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
const output = resolve(process.env.FOOSIGNPUBLIC ||
  join(root, "release", `foo-v${manifest.version}`, "key.asc"));
const backup = resolve(process.env.FOOSIGNBACKUP ||
  (process.platform === "win32"
    ? join(homedir(), "Documents", "FOO", "keys")
    : join(homedir(), ".local", "share", "foo", "keys")));
if (!email || !email.includes("@")) throw Error("Set FOOSIGNEMAIL in .env.sign");
if (/[<>\r\n]/.test(name) || /[<>\r\n]/.test(email)) throw Error("Signing identity contains unsupported characters");
if (!/^(?:0|never|\d+[dwmy]|\d{4}-\d{2}-\d{2})$/.test(expires)) {
  throw Error("FOOSIGNEXPIRES must be 0, never, a duration such as 2y, or YYYY-MM-DD");
}

const identity = `${name} <${email}>`;
const unprotected = process.argv.includes("--unprotected");
let key = fingerprint(identity);
if (process.argv.includes("--preview") || process.argv.includes("--dry-run")) {
  const article = unprotected ? "an unprotected" : "a protected";
  console.log(key ? `Would reuse release key ${key}` : `Would create ${article} Ed25519 release key for ${identity}`);
  console.log(`Would export the public key to ${output}`);
  console.log(`Would export a recoverable key pair under ${join(backup, key || "FINGERPRINT")}`);
  console.log("Would write its fingerprint to .env.sign");
  process.exit(0);
}
let phrase = unprotected ? "" : password();
if (key) {
  console.log(`Reusing release key ${key}`);
} else {
  const parameters = unprotected
    ? ["--batch", "--pinentry-mode", "loopback", "--passphrase", "", "--quick-generate-key", identity, "ed25519", "sign", expires]
    : ["--batch", "--pinentry-mode", "loopback", "--passphrase-fd", "0", "--quick-generate-key", identity, "ed25519", "sign", expires];
  console.log(`Creating ${unprotected ? "unprotected" : "protected"} release key for ${identity}`);
  run(parameters, false, [], unprotected ? undefined : `${phrase}\n`);
  key = fingerprint(identity);
  if (!key) throw Error("GPG created no discoverable secret-key fingerprint");
}

const exported = run(["--batch", "--armor", "--export", key], true);
if (!exported.includes("BEGIN PGP PUBLIC KEY BLOCK")) throw Error("GPG did not export a public key");
const options = unprotected
  ? ["--batch", "--armor", "--export-secret-keys", key]
  : ["--batch", "--pinentry-mode", "loopback", "--passphrase-fd", "0", "--armor", "--export-secret-keys", key];
const secret = run(options, true, [], unprotected ? undefined : `${phrase}\n`);
phrase = "";
if (!secret.includes("BEGIN PGP PRIVATE KEY BLOCK")) throw Error("GPG did not export a private-key backup");
const vault = join(backup, key);
mkdirSync(vault, { recursive: true });
writeFileSync(join(vault, "public.asc"), exported.endsWith("\n") ? exported : `${exported}\n`, { mode: 0o600 });
writeFileSync(join(vault, "private.asc"), secret.endsWith("\n") ? secret : `${secret}\n`, { mode: 0o600 });
mkdirSync(dirname(output), { recursive: true });
writeFileSync(output, exported.endsWith("\n") ? exported : `${exported}\n`);
save(key);

console.log(`Signing fingerprint: ${key}`);
console.log(`Public key: ${output}`);
console.log(`Private backup: ${join(vault, "private.asc")}`);
console.log(`Public backup: ${join(vault, "public.asc")}`);
console.log(`Signing environment: ${settings}`);
console.log("Copy the key backup folder to encrypted offline storage before relying on it for releases.");
