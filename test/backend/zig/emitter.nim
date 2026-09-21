import std/strutils
import ../../../src/backend/zig/emitter
import ../../../src/ir/node
import ../../../src/ir/kind

let function = Function(name: "main", ret: `Type`(kind: TypeKind.Void), params: @[], blocks: @[])
let module = Module(name: "demo", funcs: @[function], externs: @[])
let generated = emit(module, "dev")
doAssert generated.code.contains("FOO IR v1 -> Zig")
doAssert generated.code.contains("fn main")
doAssert typeStr(`Type`(kind: TypeKind.Optional, elem: `Type`(kind: TypeKind.Uint, width: 32))) == "?u32"
let covered = emit(module, "dev", EmitOptions(coverage: "coverage.json"))
doAssert covered.code.contains("var coverage")
doAssert covered.code.contains("defer report()")
try:
  discard emit(module, "dev", EmitOptions(coverage: "coverage.json", runtime: "none"))
  doAssert false
except ValueError:
  discard
echo "Zig emitter parity: ok"
