import std/[json, os, osproc, strutils, tables]
import ../../../src/backend/qbe/driver
import ../../../src/backend/qbe/wasm as wat
import ../../../src/build/options
import ../../../src/ir/[kind, node]
import ../../../src/ir/valid as validation

let integer = `Type`(kind: Shape.Int, width: 32)
let program = Module(funcs: @[Function(name: "main", ret: integer,
  blocks: @[Block(label: "entry", term: Instruction(kind: Opcode.Return,
    value: Value(kind: Flavor.Const, name: "42", `type`: integer)))])])

let wasi = build(program, "dev", ".artifacts/qbe-wasi-test",
  Native(name: "app", target: "wasi"))
doAssert wasi.success, wasi.error
doAssert fileExists(wasi.artifact)
doAssert readFile(wasi.artifact)[0 .. 3] == "\x00asm"
let metadata = parseFile(wasi.artifact & ".qbe.json")
doAssert metadata["policy"].getStr() == "wabt-direct-module-v6"
doAssert metadata["wat2wasm"]["sha256"].getStr().len == 64
let again = build(program, "dev", ".artifacts/qbe-wasi-test",
  Native(name: "app", target: "wasi"))
doAssert again.success and again.cached

let optimized = build(program, "release", ".artifacts/qbe-wasi-release-test",
  Native(name: "app", target: "wasi"))
doAssert optimized.success, optimized.error
doAssert readFile(optimized.artifact) == readFile(wasi.artifact)
doAssert parseFile(optimized.artifact & ".qbe.json")["mode"].getStr() == "release"

let objectBuild = build(program, "dev", ".artifacts/qbe-wasm-object-test",
  Native(name: "app", kind: "object", target: "wasm-freestanding"))
doAssert objectBuild.success, objectBuild.error
doAssert fileExists(objectBuild.artifact)

let u8 = `Type`(kind: Shape.Uint, width: 8)
let u32 = `Type`(kind: Shape.Uint, width: 32)
let pointer = `Type`(kind: Shape.Ptr, elem: integer)
let bytePointer = `Type`(kind: Shape.Ptr, elem: u8)
proc reg(name: string; typ: node.Type): Value =
  Value(kind: Flavor.Reg, name: name, `type`: typ)
proc number(value: string; typ: node.Type): Value =
  Value(kind: Flavor.Const, name: value, `type`: typ)
let slot = reg("slot", pointer)
let loaded = reg("loaded", integer)
let byteSlot = reg("byte_slot", bytePointer)
let byteLoaded = reg("byte_loaded", u8)
let external = reg("external", integer)
let cExternal = reg("c_external", integer)
let pair = `Type`(kind: Shape.Array, elem: integer, width: 2)
let foreignInput = reg("foreign_input", pair)
let foreignOutput = reg("foreign_output", pair)
let foreignOriginal = reg("foreign_original", integer)
let foreignResult = reg("foreign_result", integer)
let record = `Type`(kind: Shape.Struct, name: "Nested")
record.fields["items"] = pair
record.fields["sentinel"] = integer
let items = reg("items", pair)
let nested = reg("nested", record)
let extracted = reg("extracted", pair)
let indexed = reg("indexed", integer)
let counter = Value(kind: Flavor.Global, name: "counter", `type`: pointer)
let globalValue = reg("global_value", integer)
let letter = Value(kind: Flavor.Global, name: "letter", `type`: bytePointer)
let iovec = `Type`(kind: Shape.Struct, name: "WasiIovec")
iovec.fields["data"] = bytePointer
iovec.fields["length"] = u32
let vector = reg("vector", iovec)
let vectorSlot = reg("vector_slot", `Type`(kind: Shape.Ptr, elem: iovec))
let writtenSlot = reg("written_slot", `Type`(kind: Shape.Ptr, elem: u32))
let bytesWritten = reg("bytes_written", u32)
let writeStatus = reg("write_status", u32)
let readStatus = reg("read_status", u32)
let readVector = reg("read_vector", iovec)
let readVectorSlot = reg("read_vector_slot", `Type`(kind: Shape.Ptr, elem: iovec))
let readCountSlot = reg("read_count_slot", `Type`(kind: Shape.Ptr, elem: u32))
let readByteSlot = reg("read_byte_slot", bytePointer)
let readByte = reg("read_byte", u8)
let clockSlot = reg("clock_slot", `Type`(kind: Shape.Ptr,
  elem: `Type`(kind: Shape.Uint, width: 64)))
let clockValue = reg("clock_value", `Type`(kind: Shape.Uint, width: 64))
let clockStatus = reg("clock_status", u32)
let randomSlot = reg("random_slot", bytePointer)
let randomValue = reg("random_value", u8)
let randomStatus = reg("random_status", u32)
let openedFdSlot = reg("opened_fd_slot", `Type`(kind: Shape.Ptr, elem: u32))
let openedFd = reg("opened_fd", u32)
let openStatus = reg("open_status", u32)
let seekSlot = reg("seek_slot", clockSlot.type)
let seekStatus = reg("seek_status", u32)
let seekValue = reg("seek_value", clockValue.type)
let closeStatus = reg("close_status", u32)
let expanded = Module(
  storage: @[Storage(name: "counter", public: true,
    value: number("42", integer)),
    Storage(name: "letter", value: number("65", u8))],
  externs: @[Extern(name: "foreign_add", symbol: "foreign_add", abi: "wasi",
    params: @[integer, integer], ret: integer),
    Extern(name: "fd_write", symbol: "fd_write", abi: "wasi",
      params: @[u32, vectorSlot.type, u32, writtenSlot.type], ret: u32),
    Extern(name: "fd_read", symbol: "fd_read", abi: "wasi",
      params: @[u32, readVectorSlot.type, u32, readCountSlot.type], ret: u32),
    Extern(name: "clock_time_get", symbol: "clock_time_get", abi: "wasi",
      params: @[u32, clockValue.type, clockSlot.type], ret: u32),
    Extern(name: "random_get", symbol: "random_get", abi: "wasi",
      params: @[randomSlot.type, u32], ret: u32),
    Extern(name: "path_open", symbol: "path_open", abi: "wasi",
      params: @[u32, u32, bytePointer, u32, u32, clockValue.type,
        clockValue.type, u32, openedFdSlot.type], ret: u32),
    Extern(name: "fd_seek", symbol: "fd_seek", abi: "wasi",
      params: @[u32, clockValue.type, u32, seekSlot.type], ret: u32),
    Extern(name: "fd_close", symbol: "fd_close", abi: "wasi",
      params: @[u32], ret: u32),
    Extern(name: "host_add", symbol: "host_add", abi: "c",
      params: @[integer, integer], ret: integer),
    Extern(name: "host_pair", symbol: "host_pair", abi: "c",
      params: @[pair], ret: pair)],
  funcs: @[
    Function(name: "stack_roundtrip", public: true, ret: integer,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Alloc, op: "slot", region: "scope", dest: slot),
        Instruction(kind: Opcode.Store, `ptr`: slot, val: number("42", integer)),
        Instruction(kind: Opcode.Load, `ptr`: slot, dest: loaded)],
        term: Instruction(kind: Opcode.Return, value: loaded))]),
    Function(name: "byte_roundtrip", public: true, ret: u8,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Alloc, op: "slot", region: "scope", dest: byteSlot),
        Instruction(kind: Opcode.Store, `ptr`: byteSlot, val: number("42", u8)),
        Instruction(kind: Opcode.Load, `ptr`: byteSlot, dest: byteLoaded)],
        term: Instruction(kind: Opcode.Return, value: byteLoaded))]),
    Function(name: "foreign_call", public: true, ret: integer,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Call, `func`: "foreign_add", dest: external,
          args: @[number("20", integer), number("22", integer)])],
        term: Instruction(kind: Opcode.Return, value: external))]),
    Function(name: "static_roundtrip", public: true, ret: integer,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Load, `ptr`: counter, dest: globalValue)],
        term: Instruction(kind: Opcode.Return, value: globalValue))]),
    Function(name: "wasi_write", public: true, ret: u32,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Construct, dest: vector,
          args: @[letter, number("1", u32)]),
        Instruction(kind: Opcode.Alloc, op: "slot", region: "scope",
          dest: vectorSlot),
        Instruction(kind: Opcode.Store, `ptr`: vectorSlot, val: vector),
        Instruction(kind: Opcode.Alloc, op: "slot", region: "scope",
          dest: writtenSlot),
        Instruction(kind: Opcode.Call, `func`: "fd_write", dest: writeStatus,
          args: @[number("1", u32), vectorSlot, number("1", u32), writtenSlot]),
        Instruction(kind: Opcode.Load, `ptr`: writtenSlot, dest: bytesWritten)],
        term: Instruction(kind: Opcode.Return, value: bytesWritten))]),
    Function(name: "wasi_read", public: true, ret: u8,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Alloc, op: "slot", region: "scope",
          dest: readByteSlot),
        Instruction(kind: Opcode.Construct, dest: readVector,
          args: @[readByteSlot, number("1", u32)]),
        Instruction(kind: Opcode.Alloc, op: "slot", region: "scope",
          dest: readVectorSlot),
        Instruction(kind: Opcode.Store, `ptr`: readVectorSlot,
          val: readVector),
        Instruction(kind: Opcode.Alloc, op: "slot", region: "scope",
          dest: readCountSlot),
        Instruction(kind: Opcode.Call, `func`: "fd_read", dest: readStatus,
          args: @[number("0", u32), readVectorSlot,
            number("1", u32), readCountSlot]),
        Instruction(kind: Opcode.Load, `ptr`: readByteSlot,
          dest: readByte)],
        term: Instruction(kind: Opcode.Return, value: readByte))]),
    Function(name: "wasi_clock", public: true, ret: clockValue.type,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Alloc, op: "slot", region: "scope",
          dest: clockSlot),
        Instruction(kind: Opcode.Call, `func`: "clock_time_get",
          dest: clockStatus, args: @[number("1", u32),
            number("1", clockValue.type), clockSlot]),
        Instruction(kind: Opcode.Load, `ptr`: clockSlot,
          dest: clockValue)],
        term: Instruction(kind: Opcode.Return, value: clockValue))]),
    Function(name: "wasi_random", public: true, ret: u8,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Alloc, op: "slot", region: "scope",
          dest: randomSlot),
        Instruction(kind: Opcode.Call, `func`: "random_get",
          dest: randomStatus,
          args: @[randomSlot, number("1", u32)]),
        Instruction(kind: Opcode.Load, `ptr`: randomSlot,
          dest: randomValue)],
        term: Instruction(kind: Opcode.Return, value: randomValue))]),
    Function(name: "wasi_file", public: true, ret: clockValue.type,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Alloc, op: "slot", region: "scope",
          dest: openedFdSlot),
        Instruction(kind: Opcode.Call, `func`: "path_open",
          dest: openStatus, args: @[number("3", u32), number("0", u32),
            letter, number("1", u32), number("0", u32),
            number("0", clockValue.type), number("0", clockValue.type),
            number("0", u32), openedFdSlot]),
        Instruction(kind: Opcode.Load, `ptr`: openedFdSlot,
          dest: openedFd),
        Instruction(kind: Opcode.Alloc, op: "slot", region: "scope",
          dest: seekSlot),
        Instruction(kind: Opcode.Call, `func`: "fd_seek", dest: seekStatus,
          args: @[openedFd, number("42", clockValue.type),
            number("0", u32), seekSlot]),
        Instruction(kind: Opcode.Load, `ptr`: seekSlot, dest: seekValue),
        Instruction(kind: Opcode.Call, `func`: "fd_close", dest: closeStatus,
          args: @[openedFd])],
        term: Instruction(kind: Opcode.Return, value: seekValue))]),
    Function(name: "c_foreign_call", public: true, ret: integer,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Call, `func`: "host_add", dest: cExternal,
          args: @[number("20", integer), number("22", integer)])],
        term: Instruction(kind: Opcode.Return, value: cExternal))]),
    Function(name: "foreign_aggregate", public: true, ret: integer,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Construct, dest: foreignInput,
          args: @[number("20", integer), number("21", integer)]),
        Instruction(kind: Opcode.Call, `func`: "host_pair",
          dest: foreignOutput, args: @[foreignInput]),
        Instruction(kind: Opcode.Index, dest: foreignOriginal,
          val: foreignInput, val2: number("0", integer)),
        Instruction(kind: Opcode.Index, dest: foreignResult,
          val: foreignOutput, val2: number("1", integer)),
        Instruction(kind: Opcode.Add, dest: cExternal,
          val: foreignOriginal, val2: foreignResult)],
        term: Instruction(kind: Opcode.Return, value: cExternal))]),
    Function(name: "nested_record", public: true, ret: integer,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Construct, dest: items,
          args: @[number("20", integer), number("42", integer)]),
        Instruction(kind: Opcode.Construct, dest: nested,
          args: @[items, number("0", integer)]),
        Instruction(kind: Opcode.Extract, dest: extracted,
          val: nested, field: "items"),
        Instruction(kind: Opcode.Index, dest: indexed, val: extracted,
          val2: number("1", integer))],
        term: Instruction(kind: Opcode.Return, value: indexed))]),
    Function(name: "out_of_bounds", public: true, ret: integer,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Construct, dest: items,
          args: @[number("20", integer), number("42", integer)]),
        Instruction(kind: Opcode.Index, dest: indexed, val: items,
          val2: number("2", integer))],
        term: Instruction(kind: Opcode.Return, value: indexed))])])
proc binary(name: string; kind: Opcode; typ: node.Type;
    left, right: string; operation = "") =
  let answer = reg("answer", typ)
  expanded.funcs.add(Function(name: name, public: true, ret: typ,
    blocks: @[Block(label: "entry", instrs: @[
      Instruction(kind: kind, op: operation, dest: answer,
        val: number(left, typ), val2: number(right, typ))],
      term: Instruction(kind: Opcode.Return, value: answer))]))
binary("multiply32", Opcode.Mul, integer, "6", "7")
binary("multiply_overflow32", Opcode.Mul, integer, "2147483647", "2")
let integer64 = `Type`(kind: Shape.Int, width: 64)
binary("multiply64", Opcode.Mul, integer64, "6", "7")
binary("multiply_overflow64", Opcode.Mul, integer64,
  "9223372036854775807", "2")
binary("divide32", Opcode.Div, integer, "84", "2")
binary("shift_out_of_bounds", Opcode.Bit, integer, "1", "32", "shl")
let produced = reg("produced", pair)
let received = reg("received", pair)
let consumed = reg("consumed", integer)
let receivedCell = reg("received_cell", pointer)
let passed = reg("passed", pair)
let aggregateAnswer = reg("aggregate_answer", integer)
let callerValue = reg("caller_value", integer)
expanded.funcs.add(Function(name: "make_pair", ret: pair,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, dest: produced,
      args: @[number("20", integer), number("42", integer)])],
    term: Instruction(kind: Opcode.Return, value: produced))]))
expanded.funcs.add(Function(name: "read_pair", params: @[received],
  ret: integer, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Index, op: "address", dest: receivedCell,
      val: received, val2: number("1", integer)),
    Instruction(kind: Opcode.Store, `ptr`: receivedCell,
      val: number("99", integer)),
    Instruction(kind: Opcode.Index, dest: consumed, val: received,
      val2: number("1", integer))],
    term: Instruction(kind: Opcode.Return, value: consumed))]))
expanded.funcs.add(Function(name: "aggregate_call", public: true,
  ret: integer, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Call, `func`: "make_pair", dest: passed),
    Instruction(kind: Opcode.Call, `func`: "read_pair", dest: aggregateAnswer,
      args: @[passed]),
    Instruction(kind: Opcode.Index, dest: callerValue, val: passed,
      val2: number("1", integer))],
    term: Instruction(kind: Opcode.Return, value: callerValue))]))
let expandedBuild = build(expanded, "release", ".artifacts/qbe-wasm-memory-test",
  Native(name: "memory", target: "wasm-freestanding"))
doAssert expandedBuild.success, expandedBuild.error
doAssert fileExists(expandedBuild.artifact)
let execution = execCmdEx("node " &
  quoteShell(currentSourcePath().parentDir / "scripts/wasm-run.mjs") & " " &
  quoteShell(expandedBuild.artifact) & " " & quoteShell(optimized.artifact))
doAssert execution.exitCode == 0, execution.output

let ordered = `Type`(kind: Shape.Struct, name: "Ordered")
ordered.fields["first"] = integer
ordered.fields["second"] = integer
let reordered = `Type`(kind: Shape.Struct, name: "Reordered")
reordered.fields["second"] = integer
reordered.fields["first"] = integer
let reorderedArg = reg("reordered_arg", reordered)
let orderedMismatch = Module(
  externs: @[Extern(name: "accept_ordered", symbol: "accept_ordered",
    abi: "c", params: @[ordered], ret: `Type`(kind: Shape.Void))],
  funcs: @[Function(name: "send_reordered", params: @[reorderedArg],
    ret: `Type`(kind: Shape.Void),
    blocks: @[Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Call, `func`: "accept_ordered",
        args: @[reorderedArg])], term: Instruction(kind: Opcode.Return))])])
var rejectsReorderedAbi = false
try:
  discard wat.emit(orderedMismatch, false)
except ValueError as exc:
  rejectsReorderedAbi = exc.msg.contains("call argument type")
doAssert rejectsReorderedAbi

let threaded = build(program, "dev", ".artifacts/qbe-wasi-threads-test",
  Native(name: "app", target: "wasi-threads"))
doAssert not threaded.success and threaded.error.contains("threads")

let atomicWord = `Type`(kind: Shape.Uint, width: 64,
  attributes: @["atomic"])
let atomicPointer = `Type`(kind: Shape.Ptr, elem: atomicWord)
let shared = reg("shared", atomicPointer)
let previous = reg("previous", `Type`(kind: Shape.Uint, width: 64))
let atomicModule = Module(funcs: @[Function(name: "increment", public: true,
  abi: "c", params: @[shared], ret: previous.type,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Atomic, op: "add", field: "acq_rel",
      `ptr`: shared, val: number("1", previous.type), dest: previous)],
    term: Instruction(kind: Opcode.Return, value: previous))])])
discard validation.seal(atomicModule)
let unthreaded = build(atomicModule, "dev", ".artifacts/qbe-wasi-atomic-reject",
  Native(name: "atomic", kind: "object", target: "wasi"))
doAssert not unthreaded.success and unthreaded.error.contains("atomics")
let unsafeThreaded = Module(funcs: @[Function(name: "stack_in_thread",
  ret: integer, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Alloc, op: "slot", region: "scope",
      dest: reg("slot", pointer))],
    term: Instruction(kind: Opcode.Return, value: number("42", integer)))])])
let unsafeObject = build(unsafeThreaded, "dev",
  ".artifacts/qbe-wasi-threaded-stack-reject",
  Native(name: "unsafe", kind: "object", target: "wasi-threads"))
doAssert not unsafeObject.success and unsafeObject.error.contains("per-thread")
let atomicCount = `Type`(kind: Shape.Uint, width: 32,
  attributes: @["atomic"])
let countPointer = `Type`(kind: Shape.Ptr, elem: atomicCount)
let sharedCount = Value(kind: Flavor.Global, name: "thread_count",
  `type`: countPointer)
let threadId = reg("thread_id", integer)
let threadArg = reg("thread_arg", integer)
let threadSlot = reg("thread_slot", pointer)
let threadValue = reg("thread_value", integer)
let threadOld = reg("thread_old", u32)
let spawnResults = [reg("spawn_result_1", integer),
  reg("spawn_result_2", integer), reg("spawn_result_3", integer),
  reg("spawn_result_4", integer)]
let voidType = `Type`(kind: Shape.Void)
let threadedProgram = Module(
  storage: @[Storage(name: "thread_count", public: true,
    value: number("0", atomicCount))],
  externs: @[Extern(name: "spawn", symbol: "wasi_thread_spawn",
    abi: "wasi", params: @[u32], ret: integer)],
  funcs: @[
    Function(name: "main", ret: integer,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Call, `func`: "spawn", dest: spawnResults[0],
          args: @[number("1", u32)]),
        Instruction(kind: Opcode.Call, `func`: "spawn", dest: spawnResults[1],
          args: @[number("2", u32)]),
        Instruction(kind: Opcode.Call, `func`: "spawn", dest: spawnResults[2],
          args: @[number("3", u32)]),
        Instruction(kind: Opcode.Call, `func`: "spawn", dest: spawnResults[3],
          args: @[number("4", u32)])],
        term: Instruction(kind: Opcode.Return,
          value: number("0", integer)))]),
    Function(name: "thread_main", ret: voidType,
      params: @[threadId, threadArg],
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Alloc, op: "slot", region: "scope",
          dest: threadSlot),
        Instruction(kind: Opcode.Store, `ptr`: threadSlot, val: threadArg),
        Instruction(kind: Opcode.Load, `ptr`: threadSlot,
          dest: threadValue),
        Instruction(kind: Opcode.Atomic, op: "add", field: "seq_cst",
          `ptr`: sharedCount, val: number("1", u32), dest: threadOld)],
        term: Instruction(kind: Opcode.Return))])])
discard validation.seal(threadedProgram)
for mode in ["dev", "release"]:
  let threadedExe = build(threadedProgram, mode,
    ".artifacts/qbe-wasi-thread-exe-" & mode,
    Native(name: "threaded", target: "wasi-threads"))
  doAssert threadedExe.success, threadedExe.error
  let wat = readFile(".artifacts/qbe-wasi-thread-exe-" & mode & "/main.wat")
  doAssert "wasi_thread_start" in wat and "thread-spawn" in wat
  let run = execCmdEx("node " &
    quoteShell(currentSourcePath().parentDir / "scripts/wasi-thread-exe.mjs") &
    " " & quoteShell(threadedExe.artifact))
  doAssert run.exitCode == 0, run.output
for mode in ["dev", "release"]:
  let threadedObject = build(atomicModule, mode,
    ".artifacts/qbe-wasi-threads-" & mode,
    Native(name: "increment", kind: "object", target: "wasi-threads"))
  doAssert threadedObject.success, threadedObject.error
  doAssert readFile(threadedObject.artifact)[0 .. 3] == "\x00asm"
  doAssert readFile(".artifacts/qbe-wasi-threads-" & mode & "/main.wat").
    contains("i64.atomic.rmw.add")
let sdk = getEnv("FOO_QBE_WASI_SDK")
let threadRunner = getEnv("FOO_QBE_WASI_THREADS_RUNNER")
doAssert (sdk.len == 0) == (threadRunner.len == 0),
  "set both FOO_QBE_WASI_SDK and FOO_QBE_WASI_THREADS_RUNNER"
if sdk.len > 0:
  let gate = execCmdEx("node " &
    quoteShell(currentSourcePath().parentDir / "scripts/wasi-threads.mjs") & " " &
    quoteShell(absolutePath(".artifacts/qbe-wasi-threads-dev/increment.o")) &
    " " &
    quoteShell(absolutePath(".artifacts/qbe-wasi-threads-release/increment.o")))
  doAssert gate.exitCode == 0, gate.output

echo "QBE WABT WebAssembly: ok"
