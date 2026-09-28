import std/[os, strutils]

let root = currentSourcePath().parentDir().parentDir().parentDir()
let guide = readFile(root / "docs" / "tuning.md")
let contract = readFile(root / "specs" / "optimization.md")

for current in ["Generic specialization | Current",
    "Typed failure propagation | Current",
    "Adaptive byte transfer | Current"]:
  doAssert current in guide, "missing current optimization status: " & current

for current in ["Execution-specialization engine | Current",
    "Boundary elimination and pipeline fusion | Current, local",
    "Automatic allocation placement | Current, local",
    "Continuation specialization | Current, synchronous",
    "Direct serialization and generated parsing | Current",
    "Event-backed task pool | Current on hosted C",
    "PGO (profile-guided optimization using earlier run data) | Current",
    "Adaptive file and text search paths | Current on hosted runtime"]:
  doAssert current in guide, "missing scoped optimization status: " & current

for requirement in ["Optimization and Internal Implementation Review",
    "parity suite", "benchmark evidence", "status is Design"]:
  doAssert requirement in contract, "missing optimization evidence gate: " & requirement

echo "optimization status contract: ok"
