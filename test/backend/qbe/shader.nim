import std/[json, os, strutils, tables]
import ../../../src/build/project
import ../../../src/build/release as releases
import ../../../src/pkg/hash

let root = absolutePath("test/backend/qbe/fixtures/project/shader")
for mode in ["dev", "release"]:
  let built = project(root, Settings(mode: mode)).build()
  doAssert built.hasKey("shade")
  let artifact = built["shade"]
  doAssert artifact.endsWith("shade.spv") and fileExists(artifact)
  let binary = readFile(artifact)
  doAssert binary.len >= 4 and binary[0 .. 3] == "\x03\x02\x23\x07"
  let metadata = parseFile(artifact & ".json")
  doAssert metadata["backend"].getStr() == "qbe"
  doAssert metadata["format"].getStr() == "SPIR-V"
  doAssert metadata["targetEnvironment"].getStr() == "vulkan1.3"
  doAssert metadata["entry"].getStr() == "shade"
  doAssert metadata["sha256"].getStr() == digest(binary)
  doAssert metadata["validatorSha256"].getStr().len == 64

let bundle = releases.bundle(project(root, Settings(mode: "release")))
let staged = bundle.directory / "shade.spv"
doAssert fileExists(staged) and fileExists(staged & ".json")
doAssert parseFile(staged & ".json")["sha256"].getStr() ==
  digest(readFile(staged))

echo "QBE shader project: ok"
