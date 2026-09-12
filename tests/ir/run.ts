import { parse } from "../../src/ir/parse";
import { print } from "../../src/ir/print";
import { validate } from "../../src/ir/valid";
import { readFileSync, writeFileSync, readdirSync, existsSync } from "fs";
import { join } from "path";

const fixturesDir = "tests/ir/fixtures";
const files = readdirSync(fixturesDir).filter(f => f.endsWith(".ir"));

let failed = false;

for (const file of files) {
  const srcPath = join(fixturesDir, file);
  const src = readFileSync(srcPath, "utf8");
  
  let ast: any;
  try {
    ast = parse(src);
  } catch (e: any) {
    console.error(`Parse failed for ${file}: ${e.message}`);
    failed = true;
    continue;
  }

  const errors = validate(ast);
  if (errors.length > 0) {
    console.error(`Validation failed for ${file}:`);
    for (const err of errors) {
      console.error(`  - ${err.msg}`);
    }
    failed = true;
    continue;
  }

  const printed = print(ast);
  const goldenPath = join(fixturesDir, file.replace(".ir", ".golden"));
  
  if (existsSync(goldenPath)) {
    const expected = readFileSync(goldenPath, "utf8");
    if (printed !== expected) {
      console.error(`Round-trip mismatch for ${file}`);
      console.error("=== Expected ===");
      console.error(expected);
      console.error("=== Actual ===");
      console.error(printed);
      failed = true;
    }
  } else {
    writeFileSync(goldenPath, printed);
    console.log(`Created golden file for ${file}`);
  }
}

if (failed) {
  process.exit(1);
}

console.log("IR tests passed");