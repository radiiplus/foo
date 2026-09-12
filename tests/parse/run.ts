import { Lexer } from "../../src/lex/lexer";
import { Engine } from "../../src/diag/engine";
import { Parser } from "../../src/parse/parser";
import { print } from "../../src/ast/print";
import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync } from "fs";
import { join } from "path";

const fixturesDir = "tests/parse/fixtures";

if (!existsSync(fixturesDir)) {
  mkdirSync(fixturesDir, { recursive: true });
}

const files = readdirSync(fixturesDir).filter(f => f.endsWith(".rt"));

if (files.length === 0) {
  console.log("No parse fixtures found");
  process.exit(0);
}

let failed = false;

for (const file of files) {
  const srcPath = join(fixturesDir, file);
  const src = readFileSync(srcPath, "utf8");
  
  const diag = new Engine();
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  const ast = parser.parse();
  
  const printed1 = print(ast);
  const diag2 = new Engine();
  const lexer2 = new Lexer(printed1, diag2);
  const toks2 = lexer2.lex();
  const parser2 = new Parser(toks2, diag2);
  const ast2 = parser2.parse();
  const printed2 = print(ast2);
  
  if (printed1 !== printed2) {
    console.error(`Round-trip failed for ${file}:`);
    console.error("=== First print ===");
    console.error(printed1);
    console.error("=== Second print ===");
    console.error(printed2);
    failed = true;
    continue;
  }
  
  if (file.startsWith("error")) {
    if (!diag.failed) {
      console.error(`Expected diagnostics for ${file}, but none were emitted`);
      failed = true;
      continue;
    }
    if (!ast || ast.tag !== "program") {
      console.error(`Parser crashed on ${file}`);
      failed = true;
      continue;
    }
  }
  
  const goldenPath = join(fixturesDir, file.replace(".rt", ".golden"));
  writeFileSync(goldenPath, printed1);
}

if (failed) {
  process.exit(1);
}

console.log("Parse tests passed");