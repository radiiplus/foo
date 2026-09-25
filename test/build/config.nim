import std/[json, strutils, tables]
import ../../src/build/config

var manifest = defaultManifest()
doAssert manifest.name == "app"
doAssert manifest.version == "0.1.0"
doAssert manifest.language == "1"
doAssert not manifest.hasBuild()

var product = ProductConfig(entry: "src/main.iv", kind: "exe")
var build = BuildConfig(backend: "zig", target: @["linux-x64"], products: {"app": product}.toTable)
build.tasks = %*{"version": {"kind": "text", "output": "version.iv"}}
build.hooks = %*{"prebuild": "node prepare.mjs", "postbuild": "node finish.mjs"}
manifest.build = build
manifest.dependencies = {"std/testing": "1.0.0"}.toTable
doAssert manifest.hasBuild()
doAssert manifest.build.products["app"].entry == "src/main.iv"
doAssert manifest.build.tasks["version"]["kind"].getStr() == "text"
doAssert manifest.build.hooks["prebuild"].getStr() == "node prepare.mjs"
doAssert manifest.dependencies["std/testing"] == "1.0.0"
echo "build config parity: ok"
