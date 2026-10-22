import std/[json, os, tables]
import ../../../../src/build/project

for (fixture, target) in [
  ("x64", "x64-freestanding"),
  ("arm64", "arm64-freestanding"),
  ("riscv64", "riscv64-freestanding")
]:
  let root = absolutePath("test/backend/qbe/fixtures/project/freestanding/" & fixture)
  let built = project(root, Settings(target: target, mode: "release")).build()
  doAssert built.hasKey("app")
  let artifact = built["app"]
  doAssert fileExists(artifact)
  let metadata = parseFile(artifact & ".qbe.json")
  doAssert metadata["mode"].getStr() == "release"
  doAssert metadata["target"].getStr() == target
  echo target & ": " & artifact
