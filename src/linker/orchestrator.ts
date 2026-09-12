import { Target } from "../targets/presets";
import { execSync, ExecSyncOptionsWithBufferEncoding } from "child_process";
import { join } from "path";

export interface Config {
  libs?: string[];
  frameworks?: string[];
  dynamic?: boolean;
  rpath?: string;
}

export function link(zigPath: string, target: Target, mode: string, outDir: string, config: Config): string {
  const triple = `${target.arch}-${target.os}-${target.abi === "none" ? "" : target.abi}`.replace(/-$/, "");
  
  const args = [
    "build-exe",
    join(outDir, "main.zig"),
    `-O ${mode === "release" ? "ReleaseFast" : "ReleaseSafe"}`,
    `-target ${triple}`,
    `-femit-bin=${join(outDir, "app")}`,
  ];

  if (target.libc === "musl" || target.libc === "glibc") {
    args.push("-lc");
  }

  if (config.libs) {
    for (const lib of config.libs) {
      args.push(`-l${lib}`);
    }
  }

  if (config.frameworks && target.os === "macos") {
    for (const fw of config.frameworks) {
      args.push("-framework");
      args.push(fw);
    }
  }

  if (config.dynamic) {
    args.push("-dynamic");
  }

  if (config.rpath) {
    args.push(`-rpath`);
    args.push(config.rpath);
  }

  const opts: ExecSyncOptionsWithBufferEncoding = {
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
  };

  try {
    execSync(`"${zigPath}" ${args.join(" ")}`, opts);
    return join(outDir, "app");
  } catch (err: any) {
    throw new Error(`Linker failed:\n${err.stderr || err.message}`);
  }
}