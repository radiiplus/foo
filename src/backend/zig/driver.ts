import { emit, EmitResult } from "./emitter";
import { shim } from "./shim";
import * as ir from "../../ir/node";
import { execFileSync, ExecFileSyncOptionsWithBufferEncoding } from "child_process";
import { writeFileSync, mkdirSync, existsSync } from "fs";
import { join } from "path";

export interface BuildResult {
  success: boolean;
  output?: string;
  error?: string;
}

export function build(mod: ir.Module, mode: string, outDir: string, zigPath: string = "zig"): BuildResult {
  if (!existsSync(outDir)) {
    mkdirSync(outDir, { recursive: true });
  }

  const zigMode = mode === "release" ? "ReleaseFast" : "ReleaseSafe";
  const result = emit(mod, mode);
  
  const mainPath = join(outDir, "main.zig");
  const shimPath = join(outDir, "shim.zig");
  const binPath = join(outDir, "app");

  writeFileSync(mainPath, result.code);
  writeFileSync(shimPath, shim);

  try {
    const opts: ExecFileSyncOptionsWithBufferEncoding = {
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
    };

    // Uses the dynamically resolved zigPath from the toolchain manager
    execFileSync(zigPath, [
      "build-exe",
      mainPath,
      "-O",
      zigMode,
      `-femit-bin=${binPath}`,
    ], opts);
    
    const output = execFileSync(binPath, [], opts);
    return { success: true, output };
  } catch (err: any) {
    const rawError = err.stderr || err.message;
    const remapped = remapDiagnostics(rawError, result.map, outDir);
    return { success: false, error: remapped };
  }
}

function remapDiagnostics(raw: string, map: Map<number, number>, outDir: string): string {
  const regex = new RegExp(`(${outDir.replace(/\\/g, "\\\\")}[/\\\\]main\\.zig):(\\d+):(\\d+):`, "g");
  
  return raw.replace(regex, (match, file, zigLineStr, colStr) => {
    const zigLine = parseInt(zigLineStr, 10);
    
    let arcLine = zigLine;
    let minDiff = Infinity;
    
    for (const [a, z] of map.entries()) {
      const diff = Math.abs(z - zigLine);
      if (diff < minDiff) {
        minDiff = diff;
        arcLine = a;
      }
    }
    
    return `arc_source.rt:${arcLine}:${colStr}:`;
  });
}