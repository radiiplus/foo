import std/[sequtils, strutils, tables]
import ../../src/ir/[kind, monomorph, node, reach]

let narrow = `Type`(kind: Shape.Int, width: 32)
let wide = `Type`(kind: Shape.Int, width: 64)
let placeholder = `Type`(kind: Shape.Struct, name: "T")

proc recursiverecord(member: `Type`): `Type` =
  result = `Type`(kind: Shape.Struct, name: "Node",
    fields: initOrderedTable[string, `Type`]())
  result.fields["value"] = member
  result.fields["next"] = `Type`(kind: Shape.Ptr, elem: result)

proc caller(name: string; argument: `Type`): Function =
  let input = Value(kind: Flavor.Reg, name: "input", `type`: argument)
  let output = Value(kind: Flavor.Reg, name: "output", `type`: argument)
  Function(name: name, public: true, params: @[input], ret: argument,
    blocks: @[Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Call, `func`: "identity",
        arguments: @[argument], args: @[input], dest: output)],
      term: Instruction(kind: Opcode.Return, value: output))])

let generic = Function(name: "identity", generics: @["T"],
  params: @[Value(kind: Flavor.Reg, name: "value", `type`: placeholder)],
  ret: placeholder, blocks: @[Block(label: "entry",
    term: Instruction(kind: Opcode.Return,
      value: Value(kind: Flavor.Reg, name: "value", `type`: placeholder)))])

let module = Module(name: "generic_shapes", funcs: @[
  generic, caller("use32", recursiverecord(narrow)),
  caller("use64", recursiverecord(wide))])
let specialized = monomorphize(module)
doAssert specialized.optimization.generics == 2
let calls = specialized.funcs.filterIt(it.name in ["use32", "use64"])
doAssert calls.len == 2
doAssert calls[0].blocks[0].instrs[0].func != calls[1].blocks[0].instrs[0].func
for function in calls:
  let clone = specialized.funcs.filterIt(
    it.name == function.blocks[0].instrs[0].func)
  doAssert clone.len == 1
  doAssert clone[0].ret.fields["value"].width == function.ret.fields["value"].width
  doAssert clone[0].ret.fields["next"].elem == clone[0].ret

let selected = reach(specialized, true)
doAssert selected.funcs.len == 4
doAssert selected.funcs.filterIt(it.name.startsWith("identity_")).len == 2

let again = Value(kind: Flavor.Reg, name: "again", `type`: placeholder)
let recursive = Function(name: "repeat", generics: @["T"],
  params: @[Value(kind: Flavor.Reg, name: "value", `type`: placeholder)],
  ret: placeholder, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Call, `func`: "repeat",
      arguments: @[placeholder],
      args: @[Value(kind: Flavor.Reg, name: "value", `type`: placeholder)],
      dest: again)], term: Instruction(kind: Opcode.Return, value: again))])
let invocation = caller("recursive32", narrow)
invocation.blocks[0].instrs[0].func = "repeat"
let cycle = monomorphize(Module(name: "generic_recursion",
  funcs: @[recursive, invocation]))
doAssert cycle.optimization.generics == 1
doAssert cycle.funcs.len == 2
let call = cycle.funcs[0].blocks[0].instrs[0]
let body = cycle.funcs[1].blocks[0].instrs[0]
doAssert call.func == cycle.funcs[1].name
doAssert body.func == cycle.funcs[1].name
doAssert body.arguments.len == 0
doAssert reach(cycle, true).funcs.len == 2

echo "Recursive generic shapes and reachability: ok"
