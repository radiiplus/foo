import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { Lockfile } from "./lock";
import { fetchDep } from "./fetch";
import { Engine } from "../diag/engine";
import { Code } from "../diag/code";

/**
 * Dependency Resolution
 * 
 * DESIGN DECISION: Packages declare artifacts strictly via `project.json`.
 * We deliberately DO NOT support arbitrary build hooks (e.g., `preinstall`, `postbuild`)
 * in dependencies. This ensures reproducible builds, prevents supply-chain attacks
 * via malicious build scripts, and keeps the dependency graph purely declarative.
 */

export interface Manifest {
  name: string;
  version: string;
  dependencies?: Record<string, string>;
}

export interface ResolvedDep {
  name: string;
  source: string;
  hash: string;
  path: string;
  requiredBy: string;
}

export class ResolveError extends Error {
  constructor(msg: string) { super(msg); }
}

export function resolveDeps(root: string, manifest: Manifest, lock: Lockfile | null, diag: Engine): ResolvedDep[] {
  const resolved = new Map<string, ResolvedDep>();
  const queue: { name: string; source: string; requiredBy: string }[] = [];

  if (manifest.dependencies) {
    for (const [name, source] of Object.entries(manifest.dependencies)) {
      queue.push({ name, source, requiredBy: "root" });
    }
  }

  while (queue.length > 0) {
    const { name, source, requiredBy } = queue.shift()!;
    
    if (resolved.has(name)) {
      const existing = resolved.get(name)!;
      if (existing.source !== source) {
        diag.emit(Code.PkgConflict, { start: 0, end: 0, line: 0, col: 0 }, 
          `Conflict: '${name}' required as '${source}' by '${requiredBy}', ` +
          `but already resolved as '${existing.source}' by '${existing.requiredBy}'`);
        throw new ResolveError("Dependency conflict");
      }
      continue;
    }

    const locked = lock?.packages.find(p => p.name === name && p.source === source);
    let path: string;
    let hash: string;

    const fetched = fetchDep(name, source, root);
    path = fetched.path;
    hash = fetched.hash;

    if (locked && locked.hash !== hash) {
      diag.emit(Code.PkgHashMismatch, { start: 0, end: 0, line: 0, col: 0 }, 
        `Hash mismatch for '${name}': expected ${locked.hash}, found ${hash}. ` +
        `The cache may be tampered or corrupted.`);
      throw new ResolveError("Hash mismatch");
    }

    resolved.set(name, { name, source, hash, path, requiredBy });

    const depManifestPath = join(path, "project.json");
    if (existsSync(depManifestPath)) {
      const depManifest: Manifest = JSON.parse(readFileSync(depManifestPath, "utf8"));
      if (depManifest.dependencies) {
        for (const [depName, depSource] of Object.entries(depManifest.dependencies)) {
          queue.push({ name: depName, source: depSource, requiredBy: name });
        }
      }
    }
  }

  return Array.from(resolved.values());
}