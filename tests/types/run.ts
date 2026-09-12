import { TypeChecker } from "../../src/types/checker";
import { Engine } from "../../src/diag/engine";
import { Lexer } from "../../src/lex/lexer";
import { Parser } from "../../src/parse/parser";
import { readFileSync, readdirSync, existsSync, statSync } from "fs";
import { join } from "path";

const fixturesDir = "tests/types/fixtures";

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

function runTest(filePath: string, expectErrors: boolean): TestResult {
  const name = filePath.split("/").pop()!;
  const diag = new Engine();
  const result: TestResult = { name, passed: true, errors: [] };

  const src = readFileSync(filePath, "utf8");
  const program = parse(src, diag);

  if (diag.failed) {
    result.passed = false;
    result.errors.push("parse errors");
    return result;
  }

  const checker = new TypeChecker(diag);
  checker.check(program);

  if (expectErrors) {
    if (!diag.failed) {
      result.passed = false;
      result.errors.push("expected errors but none emitted");
    }
  } else {
    if (diag.failed) {
      result.passed = false;
      for (const msg of diag.messages) {
        result.errors.push(`${msg.text} at ${msg.span.line}:${msg.span.col}`);
      }
    }
  }

  return result;
}

const results: TestResult[] = [];

// Run basic tests (should pass)
const basicDir = join(fixturesDir, "basic");
if (existsSync(basicDir)) {
  const items = readdirSync(basicDir).filter(f => f.endsWith(".rt"));
  for (const item of items) {
    results.push(runTest(join(basicDir, item), false));
  }
}

// Run error tests (should fail)
const errorsDir = join(fixturesDir, "errors");
if (existsSync(errorsDir)) {
  const items = readdirSync(errorsDir).filter(f => f.endsWith(".rt"));
  for (const item of items) {
    results.push(runTest(join(errorsDir, item), true));
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

console.log("Type tests passed");