import { createHash } from "crypto";
import { readFileSync, readdirSync } from "fs";
import { join, relative } from "path";

export function hashBuffer(buf: Buffer): string {
  const sha = createHash("sha256").update(buf).digest();
  // Multihash prefix: 0x12 (sha2-256), 0x20 (32 bytes)
  const prefix = Buffer.from([0x12, 0x20]);
  return Buffer.concat([prefix, sha]).toString("hex");
}

export function hashFile(path: string): string {
  return hashBuffer(readFileSync(path));
}

export function hashDirectory(dir: string): string {
  const files: string[] = [];
  function walk(d: string) {
    for (const entry of readdirSync(d, { withFileTypes: true })) {
      if (entry.name === ".git" || entry.name === "node_modules") continue;
      const p = join(d, entry.name);
      if (entry.isDirectory()) walk(p);
      else if (entry.isFile()) files.push(p);
    }
  }
  walk(dir);
  files.sort();
  
  const h = createHash("sha256");
  for (const f of files) {
    const rel = relative(dir, f).replace(/\\/g, "/");
    h.update(rel);
    h.update(readFileSync(f));
  }
  const sha = h.digest();
  const prefix = Buffer.from([0x12, 0x20]);
  return Buffer.concat([prefix, sha]).toString("hex");
}