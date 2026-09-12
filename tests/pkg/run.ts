import { mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "fs";
import { join } from "path";
import { vendor } from "../../src/pkg/vendor";
import { ResolveError } from "../../src/pkg/resolve";
import { readLock } from "../../src/pkg/lock";
import { clearCache } from "../../src/pkg/cache";
import { Engine } from "../../src/diag/engine";
import { Code } from "../../src/diag/code";

const tmpDir = join(process.cwd(), "tmp-pkg-test");

function setup() {
  if (existsSync(tmpDir)) rmSync(tmpDir, { recursive: true, force: true });
  mkdirSync(tmpDir, { recursive: true });

  // Level 3: C
  const dirC = join(tmpDir, "C");
  mkdirSync(dirC);
  writeFileSync(join(dirC, "project.json"), JSON.stringify({ name: "C", version: "1.0.0" }));
  writeFileSync(join(dirC, "c.rt"), "module C { }");

  // Level 2: B (depends on C)
  const dirB = join(tmpDir, "B");
  mkdirSync(dirB);
  writeFileSync(join(dirB, "project.json"), JSON.stringify({ 
    name: "B", version: "1.0.0", dependencies: { "C": "path+../C" } 
  }));
  writeFileSync(join(dirB, "b.rt"), "module B { use C. }");

  // Level 1: A (depends on B)
  const dirA = join(tmpDir, "A");
  mkdirSync(dirA);
  writeFileSync(join(dirA, "project.json"), JSON.stringify({ 
    name: "A", version: "1.0.0", dependencies: { "B": "path+../B" } 
  }));
  writeFileSync(join(dirA, "a.rt"), "module A { use B. }");
}

function testTransitive() {
  console.log("Testing: 3-level transitive deps");
  setup();
  const dirA = join(tmpDir, "A");
  const origCwd = process.cwd();
  process.chdir(dirA);
  
  vendor(dirA);
  
  const lock = readLock(join(dirA, "project.lock"));
  if (!lock || lock.packages.length !== 2) {
    throw new Error("Lockfile should contain 2 packages (B and C)");
  }
  console.log("  ✓ Lockfile generated with transitive deps");
  process.chdir(origCwd);
}

function testOffline() {
  console.log("Testing: offline rebuild (lockfile-driven)");
  const dirA = join(tmpDir, "A");
  const origCwd = process.cwd();
  process.chdir(dirA);
  
  clearCache();
  rmSync(join(dirA, "vendor"), { recursive: true, force: true });
  
  vendor(dirA);
  console.log("  ✓ Rebuilt offline successfully");
  process.chdir(origCwd);
}

function testConflict() {
  console.log("Testing: conflict reporting");
  const dirConflict = join(tmpDir, "conflict");
  mkdirSync(dirConflict, { recursive: true });
  
  const dirC1 = join(tmpDir, "C1");
  mkdirSync(dirC1);
  writeFileSync(join(dirC1, "project.json"), JSON.stringify({ name: "C", version: "1.0.0" }));
  
  const dirC2 = join(tmpDir, "C2");
  mkdirSync(dirC2);
  writeFileSync(join(dirC2, "project.json"), JSON.stringify({ name: "C", version: "2.0.0" }));

  const dirB1 = join(tmpDir, "B1");
  mkdirSync(dirB1);
  writeFileSync(join(dirB1, "project.json"), JSON.stringify({ 
    name: "B1", dependencies: { "C": "path+../C1" } 
  }));

  const dirB2 = join(tmpDir, "B2");
  mkdirSync(dirB2);
  writeFileSync(join(dirB2, "project.json"), JSON.stringify({ 
    name: "B2", dependencies: { "C": "path+../C2" } 
  }));

  writeFileSync(join(dirConflict, "project.json"), JSON.stringify({ 
    name: "root", dependencies: { "B1": "path+../B1", "B2": "path+../B2" } 
  }));

  const origCwd = process.cwd();
  process.chdir(dirConflict);
  const diag = new Engine();
  
  try {
    vendor(dirConflict, diag);
    throw new Error("Expected conflict error");
  } catch (e: any) {
    if (diag.messages.some(m => m.code === Code.PkgConflict)) {
      console.log("  ✓ Conflict correctly reported with coded diagnostic");
    } else {
      throw e;
    }
  }
  process.chdir(origCwd);
}

function testTamper() {
  console.log("Testing: tampered cache detection");
  const dirA = join(tmpDir, "A");
  const origCwd = process.cwd();
  process.chdir(dirA);
  
  const lockPath = join(dirA, "project.lock");
  const lock = JSON.parse(readFileSync(lockPath, "utf8"));
  lock.packages[0].hash = "12200000000000000000000000000000000000000000000000000000000000000000";
  writeFileSync(lockPath, JSON.stringify(lock, null, 2));
  
  const diag = new Engine();
  try {
    vendor(dirA, diag);
    throw new Error("Expected hash mismatch error");
  } catch (e: any) {
    if (diag.messages.some(m => m.code === Code.PkgHashMismatch)) {
      console.log("  ✓ Tampered cache correctly detected with coded diagnostic");
    } else {
      throw e;
    }
  }
  process.chdir(origCwd);
}

// Run Gate 9 tests
testTransitive();
testOffline();
testConflict();
testTamper();

// Cleanup
rmSync(tmpDir, { recursive: true, force: true });
console.log("Package manager tests passed");