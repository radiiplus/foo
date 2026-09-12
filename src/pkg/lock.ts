import { readFileSync, writeFileSync, existsSync } from "fs";

export interface LockedPackage {
  name: string;
  source: string;
  hash: string;
}

export interface Lockfile {
  version: number;
  packages: LockedPackage[];
}

export function readLock(path: string): Lockfile | null {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

export function writeLock(path: string, lock: Lockfile): void {
  writeFileSync(path, JSON.stringify(lock, null, 2) + "\n");
}