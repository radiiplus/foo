import { readFileSync, readdirSync, existsSync, watch, writeFileSync, mkdirSync, rmSync } from "fs";
import { execSync } from "child_process";
import { join, relative } from "path";
import * as os from "os";
import { Lexer } from "../lex/lexer";
import { Parser } from "../parse/parser";
import { Engine } from "../diag/engine";
import { Resolver } from "../sema/resolver";
import { TypeChecker } from "../types/checker";
import { lower } from "../lower/lower";
import { build } from "../backend/zig/driver";
import { getPin, detect } from "../toolchain/manager";
import * as ast from "../ast/node";

export interface TestSuite {
  name: string;
  file: string;
  line: number;
}

export interface TestResult {
  suite: TestSuite;
  passed: boolean;
  timeMs: number;
  output: string;
  error: string;
}

/**
 * Discovers all `.rt` files in the given root and extracts `test "name" {}` blocks.
 */
export function discoverTests(root: string): TestSuite[] {
  const suites: TestSuite[] = [];
  
  function walk(dir: string) {
    if (!existsSync(dir)) return;
    const entries = readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      const path = join(dir, entry.name);
      if (entry.isDirectory() && entry.name !== "node_modules" && entry.name !== ".tratio-build" && entry.name !== ".tratio-test") {
        walk(path);
      } else if (entry.name.endsWith(".rt")) {
        const src = readFileSync(path, "utf8");
        const diag = new Engine();
        const lexer = new Lexer(src, diag);
        const toks = lexer.lex();
        const parser = new Parser(toks, diag);
        const program = parser.parse();
        
        for (const mod of program.mods) {
          for (const stmt of mod.body.stmts) {
            if (stmt.tag === "test") {
              suites.push({
                name: (stmt as ast.TestBlock).name.value,
                file: path,
                line: stmt.span.line
              });
            }
          }
        }
      }
    }
  }
  
  walk(root);
  return suites;
}

/**
 * Synthesizes a `start()` entry point for modules containing `test` blocks.
 * Converts `test "name" { ... }` into private functions and calls them sequentially.
 * If a `start()` function already exists, it prepends the test calls to it.
 */
function synthesizeTests(program: ast.Program): void {
  for (const mod of program.mods) {
    const testBlocks = mod.body.stmts.filter((s): s is ast.TestBlock => s.tag === "test");
    if (testBlocks.length === 0) continue;

    // 1. Convert test blocks to private functions
    const testFuncs: ast.Function[] = testBlocks.map((tb, i) => ({
      span: tb.span,
      tag: "function",
      public: false,
      name: { span: tb.span, tag: "name", text: `__test_${i}` },
      params: [],
      body: tb.body
    }));

    // 2. Create statements to call these test functions
    const callStmts: ast.Statement[] = testFuncs.map((tf) => ({
      span: tf.span,
      tag: "action",
      name: { span: tf.span, tag: "name", text: tf.name.text },
      args: []
    }));

    // 3. Check if `start` already exists
    const existingStart = mod.body.stmts.find(
      s => s.tag === "function" && (s as ast.Function).name.text === "start"
    ) as ast.Function | undefined;

    if (existingStart) {
      // Prepend test calls to the existing start function's body
      existingStart.body.stmts.unshift(...callStmts);
    } else {
      // Create a new public start function
      const dummySpan = { start: 0, end: 0, line: 1, col: 1 };
      const startFunc: ast.Function = {
        span: dummySpan,
        tag: "function",
        public: true,
        name: { span: dummySpan, tag: "name", text: "start" },
        params: [],
        body: { span: dummySpan, tag: "block", stmts: callStmts }
      };
      mod.body.stmts.push(...testFuncs, startFunc);
    }

    // 4. Remove the original test block statements from the module body
    mod.body.stmts = mod.body.stmts.filter(s => s.tag !== "test");
  }
}

/**
 * Compiles and executes a single test file.
 */
function runSingleTest(suite: TestSuite, projectRoot: string): TestResult {
  const startMs = Date.now();
  const src = readFileSync(suite.file, "utf8");
  const diag = new Engine();
  
  // 1. Parse
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  let program = parser.parse();
  
  if (diag.failed) {
    return { suite, passed: false, timeMs: Date.now() - startMs, output: "", error: "Parse failed" };
  }

  // 2. Synthesize test entry points
  synthesizeTests(program);

  // 3. Resolve
  const resolver = new Resolver(diag, projectRoot);
  resolver.resolve(program, "test_runner");
  if (diag.failed) {
    return { suite, passed: false, timeMs: Date.now() - startMs, output: "", error: "Resolution failed" };
  }

  // 4. Type Check
  const checker = new TypeChecker(diag);
  checker.check(program);
  if (diag.failed) {
    return { suite, passed: false, timeMs: Date.now() - startMs, output: "", error: "Type check failed" };
  }

  // 5. Lower to IR
  const irMod = lower(program);

  // 6. Build
  const outDir = join(os.tmpdir(), `tratio-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  mkdirSync(outDir, { recursive: true });
  
  const pinnedVersion = getPin() || "0.16.0";
  const toolchain = detect(pinnedVersion) || { version: pinnedVersion, path: "zig" };
  
  try {
    const buildResult = build(irMod, "dev", outDir, toolchain.path);
    if (!buildResult.success) {
      return { suite, passed: false, timeMs: Date.now() - startMs, output: "", error: buildResult.error || "Build failed" };
    }

    // 7. Execute
    const execResult = execSync(join(outDir, "app"), { 
      encoding: "utf8", 
      maxBuffer: 10 * 1024 * 1024,
      stdio: ["pipe", "pipe", "pipe"]
    });
    
    // Cleanup
    rmSync(outDir, { recursive: true, force: true });

    return { 
      suite, 
      passed: true, 
      timeMs: Date.now() - startMs, 
      output: execResult.toString().trim(), 
      error: "" 
    };
  } catch (e: any) {
    // Cleanup on failure
    if (existsSync(outDir)) {
      rmSync(outDir, { recursive: true, force: true });
    }
    return { 
      suite, 
      passed: false, 
      timeMs: Date.now() - startMs, 
      output: e.stdout || "", 
      error: e.stderr || e.message 
    };
  }
}

/**
 * Orchestrates test discovery, execution, reporting, and watch mode.
 */
export function runTests(
  root: string = process.cwd(), 
  filter?: string, 
  watchMode: boolean = false, 
  junitPath?: string
): void {
  let suites = discoverTests(root);
  
  // If no explicit `test` blocks were found, fallback to running any `.rt` file 
  // in the `tests/` directory that has a `start()` function (e.g., stdlib tests).
  if (suites.length === 0 && existsSync(join(root, "tests"))) {
    const testFiles = readdirSync(join(root, "tests"), { recursive: true })
      .filter((f: any) => f.toString().endsWith(".rt"))
      .map((f: any) => join(root, "tests", f.toString()));
    
    suites = testFiles.map((file: string) => ({
      name: file.split("/").pop()!.replace(".rt", ""),
      file,
      line: 1
    }));
  }

  if (filter) {
    suites = suites.filter(s => s.name.includes(filter));
  }
  
  console.log(`Found ${suites.length} test suites.`);
  
  const run = () => {
    let passed = 0;
    let failed = 0;
    const results: any[] = [];
    
    for (const suite of suites) {
      const result = runSingleTest(suite, root);
      
      if (result.passed) {
        console.log(`  ✓ ${result.suite.name} (${relative(root, result.suite.file)}:${result.suite.line}) [${result.timeMs}ms]`);
        passed++;
      } else {
        console.log(`  ✗ ${result.suite.name} (${relative(root, result.suite.file)}:${result.suite.line})`);
        console.log(`    Error: ${result.error}`);
        if (result.output) {
          console.log(`    Output: ${result.output}`);
       0}
        failed++;
      }
      
      results.push({ 
        name: result.suite.name, 
        classname: relative(root, result.suite.file), 
        time: (result.timeMs / 1000).toFixed(3),
        failure: result.passed ? undefined : result.error
      });
    }
    
    console.log(`\n${passed} passed, ${failed} failed.`);
    
    if (junitPath) {
      const xml = `<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="tratio" tests="${passed + failed}" failures="${failed}">
${results.map(r => `  <testcase name="${r.name}" classname="${r.classname}" time="${r.time}">${r.failure ? `<failure message="${r.failure.replace(/"/g, '&quot;')}"/>` : ""}</testcase>`).join("\n")}
</testsuite>`;
      writeFileSync(junitPath, xml);
      console.log(`JUnit report written to ${junitPath}`);
    }

    if (failed > 0) {
      process.exitCode = 1;
    }
  };
  
  run();
  
  if (watchMode) {
    console.log("\nWatching for changes...");
    watch(root, { recursive: true }, (event, filename) => {
      if (filename && filename.endsWith(".rt")) {
        console.log(`\nChange detected: ${filename}`);
        // Reset exit code for watch mode re-runs
        process.exitCode = 0;
        run();
      }
    });
  }
}