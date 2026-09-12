import { Module } from "../ir/module";

/**
 * The ONLY module in the entire codebase allowed to know about Zig.
 * It translates the stable Tratio IR (v1) into Zig source code.
 */
export interface Emitter {
  emit(module: Module): Promise<Output>;
}

export interface Output {
  files: Map<string, string>;
}