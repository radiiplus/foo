import ../../src/backend/substrate

let release = Selection(target: "linux-x64-v3", cpu: "x86-64-v3", mode: "release")
doAssert select("copy", release).implementation == "avx"
doAssert select("atomic", release).implementation == "c11"
let machine = Selection(target: "linux-x64", mode: "release", level: "machine")
doAssert select("copy", machine).stage == "@asm"
echo "substrate parity: ok"
