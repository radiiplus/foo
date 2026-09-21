import ../../src/targets/presets

doAssert resolve("linux-x64-v3").features == @["avx2"]
doAssert resolve("wasi").arch == "wasm32"
var rejected = false
try: discard resolve("unknown")
except ValueError: rejected = true
doAssert rejected
echo "target presets parity: ok"
