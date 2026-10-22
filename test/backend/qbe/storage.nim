import std/[os, strutils, tables]
import ../../../src/backend/qbe/emitter
import ../../../src/ir/[kind, node]

let i32 = `Type`(kind: Shape.Int, width: 32)
let u8 = `Type`(kind: Shape.Uint, width: 8)
let f64 = `Type`(kind: Shape.Float, width: 64)
let staticRecord = `Type`(kind: Shape.Struct,
  fields: toOrderedTable({"count": i32, "amount": f64}))
let slice = `Type`(kind: Shape.Slice, elem: u8)
let optional = `Type`(kind: Shape.Optional, elem: i32)
let failable = `Type`(kind: Shape.Failable, elem: i32)
let pointer = `Type`(kind: Shape.Ptr, elem: i32)
let cell = Value(kind: Flavor.Global, name: "thread_cell", `type`: pointer)
let input = Value(kind: Flavor.Reg, name: "input", `type`: i32)
let output = Value(kind: Flavor.Reg, name: "output", `type`: i32)

let getter = Function(name: "qbe_tls_get", public: true, abi: "c", ret: i32,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Load, `ptr`: cell, dest: output)],
    term: Instruction(kind: Opcode.Return, value: output))])
let setter = Function(name: "qbe_tls_set", public: true, abi: "c",
  params: @[input], ret: `Type`(kind: Shape.Void),
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Store, `ptr`: cell, val: input)],
    term: Instruction(kind: Opcode.Return))])

let vectorType = `Type`(kind: Shape.Vector, elem: i32, width: 2)
let first = Value(kind: Flavor.Reg, name: "first", `type`: vectorType)
let second = Value(kind: Flavor.Reg, name: "second", `type`: vectorType)
let combined = Value(kind: Flavor.Reg, name: "combined", `type`: vectorType)
let indexed = Value(kind: Flavor.Reg, name: "indexed", `type`: i32)
let vectorAdd = Function(name: "qbe_vector_add", public: true, abi: "c",
  ret: i32, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, dest: first, args: @[
      Value(kind: Flavor.Const, name: "11", `type`: i32),
      Value(kind: Flavor.Const, name: "22", `type`: i32)]),
    Instruction(kind: Opcode.Construct, dest: second, args: @[
      Value(kind: Flavor.Const, name: "33", `type`: i32),
      Value(kind: Flavor.Const, name: "44", `type`: i32)]),
    Instruction(kind: Opcode.Add, dest: combined, val: first, val2: second),
    Instruction(kind: Opcode.Index, dest: indexed, val: combined,
      val2: Value(kind: Flavor.Const, name: "1",
        `type`: `Type`(kind: Shape.Uint, width: 32)))],
    term: Instruction(kind: Opcode.Return, value: indexed))])

let recordType = `Type`(kind: Shape.Struct,
  fields: toOrderedTable({"count": i32, "amount": f64}))
let recordLeft = Value(kind: Flavor.Reg, name: "left_record", `type`: recordType)
let recordRight = Value(kind: Flavor.Reg, name: "right_record", `type`: recordType)
let boolean = `Type`(kind: Shape.Bool)
let recordEqual = Value(kind: Flavor.Reg, name: "equal", `type`: boolean)
let recordLess = Value(kind: Flavor.Reg, name: "less", `type`: boolean)
let equalRecords = Function(name: "qbe_record_equal", public: true, abi: "c",
  params: @[recordLeft, recordRight], ret: boolean,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Compare, op: "equals", dest: recordEqual,
      val: recordLeft, val2: recordRight)],
    term: Instruction(kind: Opcode.Return, value: recordEqual))])
let lessRecords = Function(name: "qbe_record_less", public: true, abi: "c",
  params: @[recordLeft, recordRight], ret: boolean,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Compare, op: "is less than", dest: recordLess,
      val: recordLeft, val2: recordRight)],
    term: Instruction(kind: Opcode.Return, value: recordLess))])

let i64 = `Type`(kind: Shape.Int, width: 64)
let unionType = `Type`(kind: Shape.ExternUnion,
  fields: toOrderedTable({"number": i64, "decimal": f64}))
let unionInput = Value(kind: Flavor.Reg, name: "union_input", `type`: unionType)
let unionNumber = Value(kind: Flavor.Reg, name: "union_number", `type`: i64)
let unionRead = Function(name: "qbe_union_read", public: true, abi: "c",
  params: @[unionInput], ret: i64,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Extract, field: "number", val: unionInput,
      dest: unionNumber)],
    term: Instruction(kind: Opcode.Return, value: unionNumber))])
let taggedType = `Type`(kind: Shape.TaggedUnion,
  variants: toOrderedTable({"number": i64, "decimal": f64}))
let taggedValue = Value(kind: Flavor.Reg, name: "tagged", `type`: taggedType)
let taggedTag = Value(kind: Flavor.Reg, name: "tag", `type`:
  `Type`(kind: Shape.Uint, width: 32))
let taggedProbe = Function(name: "qbe_tagged_tag", public: true, abi: "c",
  ret: taggedTag.type, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, field: "decimal", dest: taggedValue,
      args: @[Value(kind: Flavor.Const, name: "1.25", `type`: f64)]),
    Instruction(kind: Opcode.Extract, field: "tag", val: taggedValue,
      dest: taggedTag)],
    term: Instruction(kind: Opcode.Return, value: taggedTag))])

let u3 = `Type`(kind: Shape.Uint, width: 3)
let i5 = `Type`(kind: Shape.Int, width: 5)
let packedType = `Type`(kind: Shape.PackedStruct,
  fields: toOrderedTable({"low": u3, "flag": boolean, "high": i5}))
let packedValue = Value(kind: Flavor.Reg, name: "packed", `type`: packedType)
let packedHigh = Value(kind: Flavor.Reg, name: "high", `type`: i5)
let packedProbe = Function(name: "qbe_packed_high", public: true, abi: "c",
  ret: i5, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, dest: packedValue, args: @[
      Value(kind: Flavor.Const, name: "5", `type`: u3),
      Value(kind: Flavor.Const, name: "true", `type`: boolean),
      Value(kind: Flavor.Const, name: "-7", `type`: i5)]),
    Instruction(kind: Opcode.Extract, field: "high", val: packedValue,
      dest: packedHigh)],
    term: Instruction(kind: Opcode.Return, value: packedHigh))])

let volatileI32 = `Type`(kind: Shape.Int, width: 32, volatile: true)
let volatilePointer = `Type`(kind: Shape.Ptr, elem: volatileI32)
let volatileAddress = Value(kind: Flavor.Reg, name: "address",
  `type`: volatilePointer)
let volatileValue = Value(kind: Flavor.Reg, name: "observed",
  `type`: volatileI32)
let volatileProbe = Function(name: "qbe_volatile_roundtrip", public: true,
  abi: "c", params: @[volatileAddress], ret: volatileI32,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Load, `ptr`: volatileAddress,
      dest: volatileValue),
    Instruction(kind: Opcode.Store, `ptr`: volatileAddress,
      val: volatileValue)],
    term: Instruction(kind: Opcode.Return, value: volatileValue))])

let joined = Value(kind: Flavor.Reg, name: "joined", `type`: slice)
let joinedByte = Value(kind: Flavor.Reg, name: "joined_byte", `type`: u8)
let joinProbe = Function(name: "qbe_join_byte", public: true, abi: "c",
  ret: u8, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Add, dest: joined,
      val: Value(kind: Flavor.Const, name: "\"ab\"", `type`: slice),
      val2: Value(kind: Flavor.Const, name: "\"cd\"", `type`: slice)),
    Instruction(kind: Opcode.Index, dest: joinedByte, val: joined,
      val2: Value(kind: Flavor.Const, name: "3",
        `type`: `Type`(kind: Shape.Uint, width: 32)))],
    term: Instruction(kind: Opcode.Return, value: joinedByte))])

let taskType = `Type`(kind: Shape.Function, abi: "c",
  ret: `Type`(kind: Shape.Void))
let threadOpaque = `Type`(kind: Shape.Opaque, name: "thread")
let threadPointer = `Type`(kind: Shape.Ptr, elem: threadOpaque)
let spawnType = `Type`(kind: Shape.Failable, elem: threadPointer)
let completionType = `Type`(kind: Shape.Failable,
  elem: `Type`(kind: Shape.Void))
let task = Value(kind: Flavor.Reg, name: "task", `type`: taskType)
let spawnResult = Value(kind: Flavor.Reg, name: "spawn_result",
  `type`: spawnType)
let threadHandle = Value(kind: Flavor.Reg, name: "handle",
  `type`: threadPointer)
let completion = Value(kind: Flavor.Reg, name: "completion",
  `type`: completionType)
let spawnProbe = Function(name: "qbe_thread_spawn_task", public: true,
  abi: "c", params: @[task], ret: spawnType,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Thread, `func`: "spawn", abi: "runtime.thread",
      args: @[task], dest: spawnResult)],
    term: Instruction(kind: Opcode.Return, value: spawnResult))])
let waitProbe = Function(name: "qbe_thread_wait_task", public: true,
  abi: "c", params: @[threadHandle], ret: completionType,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Thread, `func`: "wait", abi: "runtime.thread",
      args: @[threadHandle], dest: completion)],
    term: Instruction(kind: Opcode.Return, value: completion))])
let closeProbe = Function(name: "qbe_thread_close_task", public: true,
  abi: "c", params: @[threadHandle], ret: completionType,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Thread, `func`: "close", abi: "runtime.thread",
      args: @[threadHandle], dest: completion)],
    term: Instruction(kind: Opcode.Return, value: completion))])

let module = Module(funcs: @[getter, setter, vectorAdd, equalRecords,
  lessRecords, unionRead, taggedProbe, packedProbe, volatileProbe,
  joinProbe, spawnProbe, waitProbe, closeProbe], storage: @[
  Storage(name: "negative_zero", value: Value(kind: Flavor.Const,
    name: "0", bits: "8000000000000000", `type`: f64)),
  Storage(name: "text", value: Value(kind: Flavor.Const,
    name: "\"abc\"", `type`: slice)),
  Storage(name: "present", value: Value(kind: Flavor.Const,
    name: "7", `type`: optional)),
  Storage(name: "failure_free", value: Value(kind: Flavor.Const,
    name: "9", `type`: failable)),
  Storage(name: "static_record", value: Value(kind: Flavor.Const,
    bits: "07000000000000000000000000000440", `type`: staticRecord)),
  Storage(name: "thread_cell", thread: true, value: Value(kind: Flavor.Const,
    name: "5", `type`: i32))], externs: @[
  Extern(name: "spawn", symbol: "spawn", abi: "runtime.thread",
    params: @[taskType], ret: spawnType),
  Extern(name: "wait", symbol: "wait", abi: "runtime.thread",
    params: @[threadPointer], ret: completionType),
  Extern(name: "close", symbol: "close", abi: "runtime.thread",
    params: @[threadPointer], ret: completionType)])

let il = emit(module, target = "linux-x64")
doAssert "thread data $storage.thread_cell" in il
doAssert "thread $storage.thread_cell" in il
doAssert "d -9223372036854775808" in il
doAssert "l $qbe.bytes." in il
doAssert "data $storage.static_record" in il
doAssert "foo_qbe_volatile_load32" in il
doAssert "foo_qbe_volatile_store32" in il
doAssert "foo_qbe_thread_spawn" in il
if getEnv("FOO_QBE_STORAGE_OUTPUT").len > 0:
  writeFile(getEnv("FOO_QBE_STORAGE_OUTPUT"), il)
try:
  discard emit(module, target = "windows-x64")
  doAssert false, "Windows QBE must reject thread-local storage"
except ValueError as error:
  doAssert "thread-local storage requires target TLS setup on windows-x64" in error.msg

echo "QBE storage probe: ok"
