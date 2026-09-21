import std/strutils
import ../../src/backend/c/emitter
import ../../src/ir/node
import ../../src/ir/kind

let function = Function(name: "main", params: @[], ret: `Type`(kind: TypeKind.Void), blocks: @[
  Block(label: "entry", instrs: @[], term: Instruction(kind: InstrKind.Return))
])
let module = Module(name: "demo", funcs: @[function], externs: @[])
let generated = emit(module)
doAssert generated.code.contains("foo_symbol_main")
doAssert generated.code.contains("#include <stdint.h>")
echo "C emitter parity: ok"
