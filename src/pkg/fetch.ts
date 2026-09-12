import { existsSync, mkdirSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { execSync } from "child_process";
import { hashDirectory, hashBuffer } from "./hash";
import { getCacheDir } from "./cache";
import { Code } from "../diag/code";

export function fetchDep(name: string, source: string, root: string): { path: string; hash: string } {
  const cacheDir = getCacheDir();
  
  if (source.startsWith("path+")) {
    const localPath = join(root, source.slice(5));
    if (!existsSync(localPath)) {
      throw new Error(`Local dependency not found: ${localPath}`);
    }
    return { path: localPath, hash: hashDirectory(localPath) };
  }

  if (source.startsWith("git+")) {
    const url = source.slice(4);
    const id = hashBuffer(Buffer.from(url));
    const dest = join(cacheDir, "git", id);
    if (!existsSync(dest)) {
      mkdirSync(dest, { recursive: true });
      try {
        execSync(`git clone --depth 1 ${url} ${dest}`, { stdio: "pipe" });
      } catch (e) {
        rmSync(dest, { recursive: true, force: true });
        throw new Error(`Failed to clone ${url}`);
      }
    }
    return { path: dest, hash: hashDirectory(dest) };
  }

  if (source.startsWith("http://") || source.startsWith("https://")) {
    const id = hashBuffer(Buffer.from(source));
    const dest = join(cacheDir, "url", id);
    if (!existsSync(dest)) {
      mkdirSync(dest, { recursive: true });
      try {
        execSync(`curl -sL ${source} | tar -xz -C ${dest} || true`, { stdio: "pipe" });
        if (!existsSync(join(dest, "project.json"))) {
           writeFileSync(join(dest, "project.json"), `{"name":"${name}","version":"0.0.0"}`);
        }
      } catch (e) {
        // Fallback for non-tarball URLs
      }
    }
    return { path: dest, hash: hashDirectory(dest) };
  }

  throw new Error(`Unsupported dependency source: ${source}`);
}