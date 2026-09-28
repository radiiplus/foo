import std/strutils
import ../../../src/backend/c/emitter
import ../../../src/ir/node
import ../../../src/ir/kind

let function = Function(name: "main", params: @[], ret: `Type`(kind: TypeKind.Void), blocks: @[
  Block(label: "entry", instrs: @[], term: Instruction(kind: InstrKind.Return))
])
let module = Module(name: "demo", funcs: @[function], externs: @[])
let generated = emit(module)
doAssert generated.code.contains("foo_symbol_main")
doAssert generated.code.contains("#include <stdint.h>")
doAssert not generated.code.contains("#define FOO_BENCHMARK 1")
let measured = emit(module, options = Options(benchmark: true))
doAssert measured.code.contains("#define FOO_BENCHMARK 1")
doAssert measured.code.contains("foo_benchmark_report()")
echo "C emitter parity: ok"
