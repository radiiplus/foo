import { existsSync, mkdirSync, cpSync, rmSync, readFileSync } from "fs";
import { join } from "path";
import { resolveDeps, Manifest } from "./resolve";
import { readLock, writeLock, Lockfile } from "./lock";
import { Engine } from "../diag/engine";

export function vendor(root: string = process.cwd(), diag: Engine = new Engine()): void {
  const manifestPath = join(root, "project.json");
  if (!existsSync(manifestPath)) {
    throw new Error("No project.json found in current directory");
  }
  const manifest: Manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const lockPath = join(root, "project.lock");
  const lock = readLock(lockPath);

  const deps = resolveDeps(root, manifest, lock, diag);
  if (diag.failed) throw new Error("Resolution failed");
  
  const vendorDir = join(root, "vendor");
  if (existsSync(vendorDir)) rmSync(vendorDir, { recursive: true, force: true });
  mkdirSync(vendorDir, { recursive: true });

  const newLock: Lockfile = { version: 1, packages: [] };

  for (const dep of deps) {
    const dest = join(vendorDir, dep.name);
    cpSync(dep.path, dest, { recursive: true });
    newLock.packages.push({
      name: dep.name,
      source: dep.source,
      hash: dep.hash
    });
  }

  writeLock(lockPath, newLock);
}