import std/[os, strutils, json]
import ../../src/pkg/hash
import ../../src/toolchain/native
import ../../src/build/execute

putEnv("FOO_OFFLINE", "1")
doAssert prepare(@[], @[], "missing-compiler", "").links.len == 0
when defined(windows) and defined(amd64):
  let bundled = prepare(@["sodium", "z"], @[], "missing-compiler", "x86_64-windows-msvc")
  doAssert bundled.headers.len == 2 and bundled.links.len == 2
  doAssert bundled.defines == @["SODIUM_STATIC=1"]
  doAssert fileExists(bundled.headers[0] / "sodium.h")
  doAssert fileExists(bundled.links[0].path)
var failed = false
try: discard prepare(@["sodium"], @[], "missing-compiler", "wasm32-wasi")
except IOError as error:
  failed = error.msg.contains("No qualified controlled")
doAssert failed
for command in ["apt-get download libsodium-dev", "curl https://example.invalid/source", "wget source", "brew install zlib"]:
  failed = false
  try: offline(command)
  except IOError: failed = true
  doAssert failed
offline("clang -I vendor/curl/include -c main.c -o main.o")
# Integrity rejection precedes any compiler invocation or network access.
let fixture = getTempDir() / ("foo-vendor-negative-" & $getCurrentProcessId())
let vendor = fixture / "vendor"
createDir(vendor)
writeFile(vendor / "manifest.json", "{\"files\":{\"bad.h\":\"0000\"}}")
writeFile(vendor / "bad.h", "tampered")
let previous = getEnv("FOO_VENDOR_ROOT")
putEnv("FOO_VENDOR_ROOT", vendor)
failed = false
try: discard verified("bad.h")
except IOError: failed = true
doAssert failed
# Cached builds must reject modified artifacts even when provenance is unchanged.
writeFile(vendor / "manifest.json", "{\"files\":{}}")
let artifacts = fixture / ".artifacts" / "vendor" /
  (when defined(windows): "windows-x64" else: "linux-x64")
createDir(artifacts)
writeFile(artifacts / "bad.a", "tampered")
writeFile(artifacts / "provenance.json", $(%*{
  "vendorIdentity": digest(readFile(vendor / "manifest.json")),
  "files": {"bad.a": "0000"}}))
failed = false
try: discard identity()
except IOError as error: failed = "Native cache input checksum mismatch" in error.msg
doAssert failed
removeDir(fixture / ".artifacts")
if previous.len == 0: delEnv("FOO_VENDOR_ROOT") else: putEnv("FOO_VENDOR_ROOT", previous)
removeFile(vendor / "manifest.json"); removeFile(vendor / "bad.h"); removeDir(vendor); removeDir(fixture)
echo "offline native dependency integrity: ok"
