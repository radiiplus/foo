import { Resolver } from "../../src/sema/resolver";
import { Engine } from "../../src/diag/engine";
import { Lexer } from "../../src/lex/lexer";
import { Parser } from "../../src/parse/parser";
import { readFileSync, readdirSync, existsSync, statSync } from "fs";
import { join } from "path";

const fixturesDir = "tests/sema/fixtures";

interface TestResult {
  name: string;
  passed: boolean;
  errors: string[];
}

function parse(src: string, diag: Engine) {
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  return parser.parse();
}

function runPackage(pkgPath: string, expectErrors: boolean): TestResult {
  const name = pkgPath.split("/").pop()!;
  const diag = new Engine();
  const results: TestResult = { name, passed: true, errors: [] };

  let entryFile: string | undefined;
  let entryName: string;
  let rootPath: string;

  if (statSync(pkgPath).isDirectory()) {
    // Multi-file package: look for .rt files DIRECTLY in this directory
    const files = readdirSync(pkgPath).filter(f => {
      const full = join(pkgPath, f);
      return f.endsWith(".rt") && statSync(full).isFile();
    });
    
    if (files.length === 0) {
      // Skip directories with no direct .rt files (they're parent dirs of nested packages)
      return { name, passed: true, errors: [] };
    }
    
    entryFile = files.find(f => f === "main.rt") || files[0];
    entryName = entryFile.replace(".rt", "");
    rootPath = pkgPath;
  } else {
    // Single file
    entryFile = pkgPath.split("/").pop()!;
    entryName = entryFile.replace(".rt", "");
    rootPath = join(pkgPath, "..");
  }

  const src = readFileSync(join(rootPath, entryFile), "utf8");
  const program = parse(src, diag);

  if (diag.failed) {
    results.passed = false;
    results.errors.push("parse errors");
    return results;
  }

  const resolver = new Resolver(diag, rootPath);
  resolver.resolve(program, entryName);

  if (expectErrors) {
    if (!diag.failed) {
      results.passed = false;
      results.errors.push("expected errors but none emitted");
    }
  } else {
    if (diag.failed) {
      results.passed = false;
      for (const msg of diag.messages) {
        results.errors.push(`${msg.text} at ${msg.span.line}:${msg.span.col}`);
      }
    }
  }

  return results;
}

const results: TestResult[] = [];

// Run basic tests (should pass)
const basicDir = join(fixturesDir, "basic");
if (existsSync(basicDir)) {
  const items = readdirSync(basicDir);
  for (const item of items) {
    const itemPath = join(basicDir, item);
    results.push(runPackage(itemPath, false));
  }
}

// Run error tests (should fail)
const errorsDir = join(fixturesDir, "errors");
if (existsSync(errorsDir)) {
  const items = readdirSync(errorsDir);
  for (const item of items) {
    const itemPath = join(errorsDir, item);
    results.push(runPackage(itemPath, true));
  }
}

// Report results
let failed = false;
for (const r of results) {
  if (r.passed) {
    console.log(`  ✓ ${r.name}`);
  } else {
    console.log(`  ✗ ${r.name}`);
    for (const err of r.errors) {
      console.log(`      ${err}`);
    }
    failed = true;
  }
}

if (failed) {
  process.exit(1);
}

console.log("Sema tests passed");