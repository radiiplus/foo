import std/strutils
import ../../src/backend/substrate

let release = Selection(target: "linux-x64-v3", cpu: "x86-64-v3", mode: "release")
doAssert select("copy", release).implementation == "avx"
doAssert "AVX2" in select("copy", release).reason
doAssert select("atomic", release).implementation == "c11"
let zigRelease = Selection(backend: "zig", target: "linux-x64-v3", cpu: "x86-64-v3", mode: "release")
doAssert select("copy", zigRelease).implementation == "block-32"
doAssert select("task", release).implementation == "epoll"
doAssert select("task", Selection(target: "windows-x64")).implementation == "iocp"
doAssert select("task", zigRelease).implementation == "threaded"
doAssert select("table", release).implementation == "open-addressing"
doAssert select("sequence-transform", release).implementation == "single-allocation"
doAssert "reserves once" in select("sequence-transform", release).reason
let machine = Selection(target: "linux-x64", mode: "release", level: "machine")
doAssert select("copy", machine).stage == "@asm"
echo "substrate parity: ok"
