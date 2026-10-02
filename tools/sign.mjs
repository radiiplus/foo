import { existsSync, openSync, readFileSync, readSync, closeSync } from "node:fs";
import { spawnSync } from "node:child_process";
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
  console.log("Usage: node tools/sign.mjs [--verify] BINARY");
  console.log("Creates or verifies BINARY.asc using GPG. FOOSIGNER selects the signing key.");
  process.exit(0);
}

const positional = process.argv.slice(2).filter(argument => !argument.startsWith("--"));
if (positional.length !== 1) throw Error("Exactly one Linux binary is required");
const binary = resolve(positional[0]);
const signature = `${binary}.asc`;
if (!existsSync(binary)) throw Error(`Linux binary does not exist: ${binary}`);
if (!elf(binary)) throw Error(`Refusing to sign a non-ELF file: ${binary}`);

const verifying = process.argv.includes("--verify");
const key = process.env.FOOSIGNER || "";
const piped = process.env.FOOSIGNPIPE === "1";
let phrase = piped ? readFileSync(0, "utf8").replace(/\r?\n$/, "") : "";
if (!verifying && !key) {
  throw Error("Set FOOSIGNER to the signing key fingerprint");
}
const parameters = verifying
  ? ["--batch", "--verify", signature, binary]
  : ["--batch", "--yes", ...(piped ? ["--pinentry-mode", "loopback", "--passphrase-fd", "0"] : []),
      "--armor", "--detach-sign", "--local-user", key,
      "--output", signature, binary];
const result = spawnSync(process.env.GPG || "gpg", parameters, {
  input: piped ? `${phrase}\n` : undefined,
  stdio: [piped ? "pipe" : "inherit", "inherit", "inherit"],
  windowsHide: true,
});
phrase = "";
if (result.error?.code === "ENOENT") {
  console.error("GPG is required to sign Linux binaries. Install gnupg and rerun this command.");
  process.exit(1);
}
if (result.status !== 0) process.exit(result.status ?? 1);
console.log(verifying ? `Verified ${signature}` : `Signed ${binary} -> ${signature}`);
