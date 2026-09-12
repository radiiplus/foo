import { existsSync, readFileSync, writeFileSync, mkdirSync } from "fs";
import { execSync } from "child_process";
import { resolve } from "../targets/presets";
import { detect, install, getPin, setPin } from "../toolchain/manager";
import { Config } from "../linker/orchestrator";
import { build as buildBackend } from "../backend/zig/driver";
import { Engine } from "../diag/engine";
import { Lexer } from "../lex/lexer";
import { Parser } from "../parse/parser";
import { Resolver } from "../sema/resolver";
import { TypeChecker } from "../types/checker";
import { lower } from "../lower/lower"; 
import { runTests } from "../test/runner";
import { format } from "../fmt/formatter";

interface Project {
  name: string;
  version: string;
  language: string;
  build?: {
    target?: string[];
    optimize?: string;
    link?: Config;
  };
  dependencies?: Record<string, string>;
}

export function check(entryFile: string): void {
  console.log(`Checking ${entryFile}...`);
  if (!existsSync(entryFile)) {
    throw new Error(`File not found: ${entryFile}`);
  }
  const src = readFileSync(entryFile, "utf8");
  const diag = new Engine();
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  const ast = parser.parse();
  if (diag.failed) {
    console.error("Parse failed.");
    process.exit(1);
  }
  const resolver = new Resolver(diag, process.cwd());
  resolver.resolve(ast, "main");
  if (diag.failed) {
    console.error("Resolution failed.");
    process.exit(1);
  }
  const typeChecker = new TypeChecker(diag);
  typeChecker.check(ast);
  if (diag.failed) {
    console.error("Type checking failed.");
    process.exit(1);
  }
  console.log("Check passed.");
}

export async function build(entryFile: string, targetPreset?: string): Promise<void> {
  const configPath = "project.json";
  let config: Project = { name: "app", version: "0.1.0", language: "1" };
  if (existsSync(configPath)) {
    config = JSON.parse(readFileSync(configPath, "utf8"));
  }
  const preset = targetPreset || (config.build?.target?.[0]) || "linux-x64";
  const mode = config.build?.optimize || "dev";
  console.log(`Building for ${preset} (${mode})...`);
  
  // 1. Toolchain resolution (dynamic version)
  const pinnedVersion = getPin() || "0.16.0";
  let toolchain = detect(pinnedVersion);
  if (!toolchain) {
    console.log(`[Toolchain] Missing Zig ${pinnedVersion}. Fetching...`);
    toolchain = await install(pinnedVersion);
    setPin(pinnedVersion);
  }
  
  // 2. Read and compile source
  if (!existsSync(entryFile)) {
    throw new Error(`File not found: ${entryFile}`);
  }
  const src = readFileSync(entryFile, "utf8");
  const diag = new Engine();
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  const ast = parser.parse();
  if (diag.failed) {
    console.error("Parse failed.");
    process.exit(1);
  }
  const resolver = new Resolver(diag, process.cwd());
  resolver.resolve(ast, "main");
  if (diag.failed) {
    console.error("Resolution failed.");
    process.exit(1);
  }
  const typeChecker = new TypeChecker(diag);
  typeChecker.check(ast);
  if (diag.failed) {
    console.error("Type checking failed.");
    process.exit(1);
  }
  
  // 3. Lower to IR
  const irMod = lower(ast);
  
  // 4. Backend emission and linking
  const outDir = ".tratio-build";
  mkdirSync(outDir, { recursive: true });
  console.log("Emitting Zig code and compiling...");
  const result = buildBackend(irMod, mode, outDir, toolchain.path);
  if (!result.success) {
    console.error("Build failed:\n" + result.error);
    process.exit(1);
  }
  console.log(`Build successful: ${outDir}/app`);
}

export async function run(entryFile: string, targetPreset?: string): Promise<void> {
  const configPath = "project.json";
  let config: Project = { name: "app", version: "0.1.0", language: "1" };
  if (existsSync(configPath)) {
    config = JSON.parse(readFileSync(configPath, "utf8"));
  }
  const preset = targetPreset || (config.build?.target?.[0]) || "linux-x64";
  const hostPreset = process.platform === "win32" ? "windows-x64" : 
                     process.platform === "darwin" ? "macos-arm64" : "linux-x64";
  await build(entryFile, preset);
  if (preset !== hostPreset) {
    console.log(`Target ${preset} differs from host ${hostPreset}. Attempting to run via qemu...`);
    const arch = preset.includes("arm64") ? "aarch64" : "x86_64";
    try {
      execSync(`qemu-${arch} .tratio-build/app`, { stdio: "inherit" });
    } catch {
      console.error("Failed to run: qemu is not installed or target architecture is unsupported for emulation.");
      process.exit(1);
    }
  } else {
    console.log("Running...");
    execSync(`.tratio-build/app`, { stdio: "inherit" });
  }
}

export function testCmd(root: string, filter?: string, watch: boolean = false, junit?: string): void {
  console.log("Running Tratio tests...");
  runTests(root, filter, watch, junit);
}

export function fmtCmd(file: string): void {
  if (!existsSync(file)) {
    throw new Error(`File not found: ${file}`);
  }
  const src = readFileSync(file, "utf8");
  const diag = new Engine();
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  const ast = parser.parse();
  
  if (diag.failed) {
    console.error("Cannot format: parse errors present.");
    process.exit(1);
  }
  
  const formatted = format(ast);
  writeFileSync(file, formatted);
  console.log(`Formatted ${file}`);
}

export function lspCmd(): void {
  console.error("Starting Tratio LSP server...");
  // The LSP server runs over stdio, so we just require and run it.
  require("../lsp/server");
}