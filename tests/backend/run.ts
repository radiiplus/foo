import { build } from "../../src/backend/zig/driver";
import { parse } from "../../src/ir/parse";
import { mkdirSync, rmSync, existsSync } from "fs";
import { join } from "path";

const tmpDir = join(process.cwd(), "tmp-backend-test");

function runTest(name: string, irCode: string, expectFail: boolean, mode: string, expectedError?: string): boolean {
  console.log(`Testing: ${name} (${mode})`);
  
  try {
    const mod = parse(irCode);
    const result = build(mod, mode, tmpDir);
    
    if (expectFail) {
      if (result.success) {
        console.log(`  ✗ Expected failure, but succeeded`);
        return false;
      }
      if (expectedError && !result.error?.includes(expectedError)) {
        console.log(`  ✗ Failed for the wrong reason:\n${result.error}`);
        return false;
      }
      console.log(`  ✓ Correctly failed with:\n${result.error?.trim()}`);
      return true;
    } else {
      if (!result.success) {
        console.log(`  ✗ Unexpected failure:\n${result.error}`);
        return false;
      }
      console.log(`  ✓ Success. Output: "${result.output?.trim()}"`);
      return true;
    }
  } catch (e: any) {
    console.log(`  ✗ Crashed: ${e.message}`);
    return false;
  }
}

const helloIr = `
module app {
  extern "c" fn @puts(ptr<int>) -> int

  fn @main() -> void {
  entry:
    %1 = alloc scope int
    store 42, %1
    %2 = load %1
    return
  }
}
`;

// Note: For a true hello world, we'd emit a call to puts, but MVL-1 IR 
// currently lacks string literal values in instructions. We test the pipeline mechanics.

const panicIr = `
module app {
  fn @main() -> void {
  entry:
    panic "deliberate failure"
  }
}
`;

let allPassed = true;

if (existsSync(tmpDir)) {
  rmSync(tmpDir, { recursive: true });
}
mkdirSync(tmpDir, { recursive: true });

allPassed = runTest("hello_pipeline", helloIr, false, "dev") && allPassed;
allPassed = runTest("panic_dev", panicIr, true, "dev", "panic: deliberate failure") && allPassed;
allPassed = runTest("panic_release", panicIr, true, "release", "panic: deliberate failure") && allPassed;

rmSync(tmpDir, { recursive: true });

if (!allPassed) {
  process.exit(1);
}

console.log("Backend tests passed");
