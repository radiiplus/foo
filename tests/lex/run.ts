import { Lexer } from "../../src/lex/lexer";
import { Engine } from "../../src/diag/engine";
import { readFileSync, writeFileSync, existsSync } from "fs";

const src = readFileSync("tests/lex/fixtures/sample.rt", "utf8");
const diag = new Engine();
const lex = new Lexer(src, diag);
const tokens = lex.lex();

const actual = JSON.stringify(tokens, null, 2);
const goldenPath = "tests/lex/fixtures/sample.json";

// If golden file doesn't exist, create it
if (!existsSync(goldenPath)) {
  writeFileSync(goldenPath, actual);
  console.log("Created golden file");
  process.exit(0);
}

const expected = readFileSync(goldenPath, "utf8");

if (actual !== expected) {
  console.error("Mismatch!");
  writeFileSync("tests/lex/fixtures/sample.actual.json", actual);
  process.exit(1);
}

console.log("Lexer test passed");