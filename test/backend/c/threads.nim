import std/os
import ../../../src/backend/c/driver
import ../../../src/ir/node
import ../../../src/ir/kind
import ../../../src/build/options
import ../../../src/toolchain/manager

let voidType = `Type`(kind: TypeKind.Void)
let main = Function(name: "main", params: @[], ret: voidType, blocks: @[
  Block(label: "entry", instrs: @[], term: Instruction(kind: InstrKind.Return))])
let module = Module(name: "wasi", funcs: @[main])
let output = ".artifacts" / ("test-threads-" & getEnv("FOOTESTID", "local"))
let compiler = install().path
let zigCache = output & "-zigcache"
createDir(zigCache)
putEnv("ZIG_GLOBAL_CACHE_DIR", zigCache)
putEnv("ZIG_LOCAL_CACHE_DIR", zigCache / "local")
let result = build(module, "dev", output,
  Native(name: "wasi", target: "wasm32-wasi", compiler: compiler,
    compile: true, threads: true))
doAssert result.success, result.error
doAssert readFile(result.artifact)[0 .. 3] == "\0asm"
echo "C threaded WASI parity: ok"
