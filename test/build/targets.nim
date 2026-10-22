import ../../src/build/targets

doAssert stable("wasm", "linux-x64") == "wasm-freestanding"
doAssert stable("freestanding", "linux-x64") == "x64-freestanding"
doAssert stable("freestanding", "linux-arm64") == "arm64-freestanding"
doAssert stable("wasi", "windows-x64") == "wasi"
doAssert stable("darwin", "windows-x64") == "macos-x64"
doAssert choose(@["linux", "darwin", "windows"], "windows-x64") ==
  "windows-x64"
doAssert choose(@["wasm", "wasi"], "linux-x64") == "wasm-freestanding"
doAssert choose(@[], "linux-arm64") == "linux-arm64"
echo "Stable targets: ok"
