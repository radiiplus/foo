import { Resolver } from "../../src/sema/resolver";
import { Engine } from "../../src/diag/engine";
import { Lexer } from "../../src/lex/lexer";
import { Parser } from "../../src/parse/parser";
import { render } from "../../src/diag/render";
import { readFileSync, readdirSync, existsSync } from "fs";
import { join } from "path";

const fixturesDir = "tests/stdlib";

function parse(src: string, diag: Engine) {
  diag.setSource(src);
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  return parser.parse();
}

function runTest(filePath: string): boolean {
  const name = filePath.split("/").pop()!;
  const diag = new Engine();
  try {
    const src = readFileSync(filePath, "utf8");
    const program = parse(src, diag);
    if (diag.failed) {
      console.log(`  ✗ ${name}: parse errors`);
      for (const msg of diag.messages) {
        console.log(render(msg, msg.source || src));
      }
      return false;
    }
    const resolver = new Resolver(diag, process.cwd());
    resolver.resolve(program, name.replace(".rt", ""));
    if (diag.failed) {
      console.log(`  ✗ ${name}: resolution errors`);
      for (const msg of diag.messages) {
        console.log(render(msg, msg.source || src));
      }
      return false;
    }
    console.log(`  ✓ ${name}`);
    return true;
  } catch (e: any) {
    console.log(`  ✗ ${name}: ${e.message}`);
    return false;
  }
}

let allPassed = true;
if (existsSync(fixturesDir)) {
  const tests = readdirSync(fixturesDir).filter(f => f.endsWith(".rt"));
  for (const test of tests) {
    allPassed = runTest(join(fixturesDir, test)) && allPassed;
  }
}

if (!allPassed) {
  process.exit(1);
}
console.log("Stdlib tests passed");