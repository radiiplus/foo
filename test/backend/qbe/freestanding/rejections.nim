import std/strutils
import ../../../../src/backend/qbe/driver
import ../../../../src/build/options
import ../../../../src/ir/[kind, node, valid]

let integer = `Type`(kind: Shape.Uint, width: 32)
let voidType = `Type`(kind: Shape.Void)
let pointer = `Type`(kind: Shape.Ptr, elem: integer)
let allocated = Value(kind: Flavor.Reg, name: "allocated", `type`: pointer)
let heap = Module(name: "heap-rejection", funcs: @[
  Function(name: "heap_probe", public: true, abi: "c", ret: voidType,
    blocks: @[Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Alloc, op: "heap", region: "scope",
        dest: allocated)],
      term: Instruction(kind: Opcode.Return))])])
discard seal(heap)
let heapBuild = build(heap, "release", ".artifacts/qbe-rejections/heap",
  Native(name: "heap", kind: "object", target: "x64-freestanding",
    runtime: "none"))
doAssert not heapBuild.success
doAssert "requires a target allocator" in heapBuild.error, heapBuild.error

let tls = Module(name: "tls-rejection", storage: @[
  Storage(name: "cpu", public: true, thread: true,
    value: Value(kind: Flavor.Const, name: "0", `type`: integer))])
let tlsBuild = build(tls, "release", ".artifacts/qbe-rejections/tls",
  Native(name: "tls", kind: "object", target: "x64-freestanding",
    runtime: "none"))
doAssert not tlsBuild.success
doAssert "requires target TLS setup" in tlsBuild.error, tlsBuild.error

let invalidEntry = Module(name: "uefi-rejection", funcs: @[
  Function(name: "efi_main", public: true, abi: "c", ret: integer,
    blocks: @[Block(label: "entry", term: Instruction(kind: Opcode.Return,
      value: Value(kind: Flavor.Const, name: "0", `type`: integer)))])])
discard seal(invalidEntry)
let uefiBuild = build(invalidEntry, "release",
  ".artifacts/qbe-rejections/uefi", Native(name: "BAD", target: "uefi-x64",
    runtime: "none"))
doAssert not uefiBuild.success
doAssert "public C efi_main" in uefiBuild.error, uefiBuild.error
echo "QBE freestanding rejection gates: ok"
