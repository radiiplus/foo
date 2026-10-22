import std/[os, strutils]
import ../../../src/backend/qbe/driver
import ../../../src/build/options
import ../../../src/ir/[kind, node, valid]

let handle = `Type`(kind: Shape.Ptr,
  elem: `Type`(kind: Shape.Opaque, name: "EFI_HANDLE"))
let table = `Type`(kind: Shape.Ptr,
  elem: `Type`(kind: Shape.Opaque, name: "EFI_SYSTEM_TABLE"))
let status = `Type`(kind: Shape.Uint, width: 64)
let byte = `Type`(kind: Shape.Uint, width: 8)
let voidType = `Type`(kind: Shape.Void)
let image = Value(kind: Flavor.Reg, name: "image", `type`: handle)
let system = Value(kind: Flavor.Reg, name: "system", `type`: table)
let program = Module(name: "qbe-uefi", requires: "machine", funcs: @[
  Function(name: "efi_main", public: true, abi: "c", ret: status,
    params: @[image, system],
    blocks: @[Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Call, `func`: "efi_debug", args: @[
        image, system, Value(kind: Flavor.Const, name: "85", `type`: byte)])],
      term: Instruction(kind: Opcode.Return,
        value: Value(kind: Flavor.Const, name: "0", `type`: status)))])],
  externs: @[Extern(name: "efi_debug", symbol: "efi_debug", abi: "c",
    params: @[handle, table, byte], ret: voidType)])
discard seal(program)

for mode in ["dev", "release"]:
  let output = ".artifacts/qbe-uefi/" & mode
  let built = build(program, mode, output,
    Native(name: "BOOTX64", target: "uefi-x64", runtime: "none",
      sources: @["test/backend/qbe/uefi/probe.c"]))
  doAssert built.success, mode & ": " & built.error
  doAssert built.artifact.endsWith("BOOTX64.efi")
  doAssert fileExists(built.artifact)
  doAssert "$efi_debug" in readFile(output / "main.ssa")
  echo mode & ": " & built.artifact
