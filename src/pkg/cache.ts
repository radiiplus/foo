import { existsSync, mkdirSync, rmSync } from "fs";
import { join } from "path";
import * as os from "os";

export function getCacheDir(): string {
  const dir = join(os.homedir(), ".tratio", "cache");
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  return dir;
}

export function clearCache(): void {
  const dir = getCacheDir();
  if (existsSync(dir)) rmSync(dir, { recursive: true, force: true });
}