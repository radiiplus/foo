import { existsSync as exists, openSync, readFileSync as read, readSync, closeSync } from "node:fs";
import { spawnSync as invoke } from "node:child_process";
import { resolve } from "node:path";

function elf(path) {
  const descriptor = openSync(path, "r");
  try {
    const magic = Buffer.alloc(4);
    return readSync(descriptor, magic, 0, magic.length, 0) === magic.length &&
      magic.equals(Buffer.from([0x7f, 0x45, 0x4c, 0x46]));
  } finally {
    closeSync(descriptor);
  }
}

if (process.argv.includes("--help")) {
  console.log("Usage: node tools/sign.mjs [--verify] [--manifest] FILE");
  console.log("Creates or verifies an ELF or SHA256SUMS manifest signature. FOOSIGNER selects the signing fingerprint.");
  process.exit(0);
}

const positional = process.argv.slice(2).filter(argument => !argument.startsWith("--"));
if (positional.length !== 1) throw Error("Exactly one Linux binary is required");
const binary = resolve(positional[0]);
const signature = `${binary}.asc`;
const manifest = process.argv.includes("--manifest");
if (!exists(binary)) throw Error(`Signing input does not exist: ${binary}`);
if (manifest ? !/^(SHA256SUMS|SHA256SUMS\.txt)$/.test(binary.split(/[\\/]/).at(-1)) : !elf(binary))
  throw Error(manifest ? `Expected a SHA256SUMS manifest: ${binary}` : `Refusing to sign a non-ELF file: ${binary}`);

const verifying = process.argv.includes("--verify");
const key = process.env.FOOSIGNER || "";
const piped = process.env.FOOSIGNPIPE === "1";
let phrase = piped && !verifying ? read(0, "utf8").replace(/\r?\n$/, "") : "";
if (!/^[a-fA-F0-9]{40}(?:[a-fA-F0-9]{24})?$/.test(key)) {
  throw Error("Set FOOSIGNER to the full 40- or 64-digit signing key fingerprint");
}
const parameters = verifying
  ? ["--batch", "--status-fd", "1", "--verify", signature, binary]
  : ["--batch", "--yes", ...(piped ? ["--pinentry-mode", "loopback", "--passphrase-fd", "0"] : []),
      "--armor", "--detach-sign", "--local-user", key,
      "--output", signature, binary];
const result = invoke(process.env.GPG || "gpg", parameters, {
  input: piped ? `${phrase}\n` : undefined,
  encoding: "utf8",
  stdio: [piped ? "pipe" : "inherit", verifying ? "pipe" : "inherit", "inherit"],
  windowsHide: true,
});
phrase = "";
if (result.error?.code === "ENOENT") {
  console.error("GPG is required to sign Linux binaries. Install gnupg and rerun this command.");
  process.exit(1);
}
if (result.status !== 0) process.exit(result.status ?? 1);
if (verifying && !result.stdout.split(/\r?\n/).some(line =>
    line.startsWith(`[GNUPG:] VALIDSIG ${key.toUpperCase()} `)))
  throw Error(`Signature was not made by FOOSIGNER ${key}`);
console.log(verifying ? `Verified ${signature}` : `Signed ${binary} -> ${signature}`);
