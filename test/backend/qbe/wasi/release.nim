import std/[json, os, osproc, tables]
import ../../../../src/build/project
import ../../../../src/pkg/hash

let root = absolutePath("test/backend/qbe/fixtures/project/wasi")
let check = root / "check.mjs"
for mode in ["dev", "release"]:
  let built = project(root, Settings(target: "wasi", mode: mode)).build()
  doAssert built.hasKey("app")
  let artifact = built["app"]
  doAssert fileExists(artifact)
  let binary = readFile(artifact)
  doAssert binary.len >= 4 and binary[0 .. 3] == "\x00asm"
  let metadata = parseFile(artifact & ".qbe.json")
  doAssert metadata["mode"].getStr() == mode
  doAssert metadata["wasmEmitterSha256"].getStr().len == 64
  let executed = execCmdEx("node " & quoteShell(check) & " " & quoteShell(artifact))
  doAssert executed.exitCode == 0, executed.output
  echo mode & " WASI SHA-256 " & digest(binary)

echo "QBE WASI dev/release project: ok"
