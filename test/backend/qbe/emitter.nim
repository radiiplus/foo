import std/[os, strutils, tables]
import ../../../src/backend/qbe/emitter
import ../../../src/ir/[kind, node]

let integer = `Type`(kind: Shape.Int, width: 32)
let wide = `Type`(kind: Shape.Int, width: 64)
let decimal = `Type`(kind: Shape.Float, width: 64)
let boolean = `Type`(kind: Shape.Bool)
let unsigned = `Type`(kind: Shape.Uint, width: 32)
let unsignedWide = `Type`(kind: Shape.Uint, width: 64)
let single = `Type`(kind: Shape.Float, width: 32)
let pointer = `Type`(kind: Shape.Ptr, elem: wide)

proc reg(name: string; t: `Type`): Value =
  Value(kind: Flavor.Reg, name: name, `type`: t)

let condition = reg("condition", boolean)
let left = reg("left", integer)
let right = reg("right", integer)
let selected = reg("selected", integer)
let choose = Function(name: "foo_probe_choose", public: true, abi: "c",
  params: @[condition, left, right], ret: integer, blocks: @[
    Block(label: "entry", term: Instruction(kind: Opcode.Cjump,
      cond: condition, yes: "yes", no: "no")),
    Block(label: "yes", term: Instruction(kind: Opcode.Jump,
      label: "merge", args: @[left])),
    Block(label: "no", term: Instruction(kind: Opcode.Jump,
      label: "merge", args: @[right])),
    Block(label: "merge", params: @[selected],
      term: Instruction(kind: Opcode.Return, value: selected))])

let a = reg("a", decimal)
let b = reg("b", decimal)
let sum = reg("sum", decimal)
let add = Function(name: "foo_probe_add_float", public: true, abi: "c",
  params: @[a, b], ret: decimal, blocks: @[
    Block(label: "entry", instrs: @[Instruction(kind: Opcode.Add,
      dest: sum, val: a, val2: b)],
      term: Instruction(kind: Opcode.Return, value: sum))])

let input = reg("input", wide)
let slot = reg("slot", pointer)
let loaded = reg("loaded", wide)
let memory = Function(name: "foo_probe_stack", public: true, abi: "c",
  params: @[input], ret: wide, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Alloc, op: "slot", dest: slot),
      Instruction(kind: Opcode.Store, `ptr`: slot, val: input),
      Instruction(kind: Opcode.Load, `ptr`: slot, dest: loaded)],
      term: Instruction(kind: Opcode.Return, value: loaded))])

let called = reg("called", integer)
let invoke = Function(name: "foo_probe_call", public: true, abi: "c",
  params: @[left], ret: integer, blocks: @[
    Block(label: "entry", instrs: @[Instruction(kind: Opcode.Call,
      `func`: "twice", args: @[left], dest: called)],
      term: Instruction(kind: Opcode.Return, value: called))])

let callbackType = `Type`(kind: Shape.Function, abi: "c",
  params: @[integer], ret: integer)
let callback = reg("callback", callbackType)
let indirectResult = reg("indirect_result", integer)
let indirect = Function(name: "foo_probe_indirect", public: true, abi: "c",
  params: @[callback, left], ret: integer, blocks: @[
    Block(label: "entry", instrs: @[Instruction(kind: Opcode.Call,
      callee: callback, args: @[left], dest: indirectResult)],
      term: Instruction(kind: Opcode.Return, value: indirectResult))])
let externalCallback = Value(kind: Flavor.Global, name: "twice",
  `type`: callbackType)
let globalCallback = Function(name: "foo_probe_global_callback", public: true,
  abi: "c", ret: callbackType, blocks: @[
    Block(label: "entry", term: Instruction(kind: Opcode.Return,
      value: externalCallback))])
let traced = Function(name: "foo_probe_traced", public: true, abi: "c",
  params: @[left], ret: integer, blocks: @[
    Block(label: "entry", instrs: @[Instruction(kind: Opcode.Trace,
      trace: "qbe-verified", span: Location(file: "probe.iv", start: 23))],
      term: Instruction(kind: Opcode.Return, value: left))])
let panicked = Function(name: "foo_probe_panic", public: true, abi: "c",
  ret: `Type`(kind: Shape.Void), blocks: @[
    Block(label: "entry", term: Instruction(kind: Opcode.Panic,
      msg: "ExpectedPanic", span: Location(file: "probe.iv", start: 31)))])

var recordFields = initOrderedTable[string, `Type`]()
recordFields["left"] = integer
recordFields["right"] = integer
let recordType = `Type`(kind: Shape.Struct, fields: recordFields)
let recordValue = reg("record_value", recordType)
let recordField = reg("record_field", integer)
let recordFieldPointer = reg("record_field_pointer",
  `Type`(kind: Shape.Ptr, elem: integer))
let recordRead = Function(name: "foo_probe_record_read", public: true,
  abi: "c", params: @[left, right], ret: integer, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Construct, dest: recordValue,
        args: @[left, right]),
      Instruction(kind: Opcode.Extract, dest: recordField,
        val: recordValue, field: "right")],
      term: Instruction(kind: Opcode.Return, value: recordField))])
let recordAddress = Function(name: "foo_probe_record_address", public: true,
  abi: "c", params: @[left, right], ret: integer, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Construct, dest: recordValue,
        args: @[left, right]),
      Instruction(kind: Opcode.Extract, op: "address", dest: recordFieldPointer,
        val: recordValue, field: "right"),
      Instruction(kind: Opcode.Load, dest: recordField,
        `ptr`: recordFieldPointer)],
      term: Instruction(kind: Opcode.Return, value: recordField))])

var mixedFields = initOrderedTable[string, `Type`]()
mixedFields["count"] = integer
mixedFields["amount"] = decimal
let mixedType = `Type`(kind: Shape.ExternStruct, fields: mixedFields)
let mixedInput = reg("mixed_input", mixedType)
let mixedOutput = reg("mixed_output", mixedType)
let mixedIdentity = Function(name: "foo_probe_mixed_identity", public: true,
  abi: "c", params: @[mixedInput], ret: mixedType,
  blocks: @[Block(label: "entry", term: Instruction(kind: Opcode.Return,
    value: mixedInput))])
let mixedExternal = Function(name: "foo_probe_mixed_external", public: true,
  abi: "c", params: @[mixedInput], ret: mixedType,
  blocks: @[Block(label: "entry", instrs: @[Instruction(kind: Opcode.Call,
    `func`: "advance_mixed", args: @[mixedInput], dest: mixedOutput)],
    term: Instruction(kind: Opcode.Return, value: mixedOutput))])
var largeFields = initOrderedTable[string, `Type`]()
largeFields["first"] = wide
largeFields["second"] = wide
largeFields["third"] = wide
let largeType = `Type`(kind: Shape.ExternStruct, fields: largeFields)
let largeInput = reg("large_input", largeType)
let largeIdentity = Function(name: "foo_probe_large_identity", public: true,
  abi: "c", params: @[largeInput], ret: largeType,
  blocks: @[Block(label: "entry", term: Instruction(kind: Opcode.Return,
    value: largeInput))])

let arrayType = `Type`(kind: Shape.Array, elem: integer, width: 3)
let arrayValue = reg("array_value", arrayType)
let arrayIndex = reg("array_index", `Type`(kind: Shape.Uint, width: 32))
let arrayItem = reg("array_item", integer)
let arrayLength = reg("array_length", `Type`(kind: Shape.Uint, width: 32))
let items = @[Value(kind: Flavor.Const, name: "11", `type`: integer),
  Value(kind: Flavor.Const, name: "22", `type`: integer),
  Value(kind: Flavor.Const, name: "33", `type`: integer)]
let indexed = Function(name: "foo_probe_array_index", public: true,
  abi: "c", params: @[arrayIndex], ret: integer, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Construct, dest: arrayValue, args: items),
      Instruction(kind: Opcode.Index, dest: arrayItem,
        val: arrayValue, val2: arrayIndex)],
      term: Instruction(kind: Opcode.Return, value: arrayItem))])
let length = Function(name: "foo_probe_array_length", public: true,
  abi: "c", ret: arrayLength.type, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Construct, dest: arrayValue, args: items),
      Instruction(kind: Opcode.Length, dest: arrayLength, val: arrayValue)],
      term: Instruction(kind: Opcode.Return, value: arrayLength))])

let optionalType = `Type`(kind: Shape.Optional, elem: integer)
let optionalValue = reg("optional_value", optionalType)
let optionalPresent = reg("optional_present", boolean)
let optionalPayload = reg("optional_payload", integer)
let optionalSome = Function(name: "foo_probe_optional_some", public: true,
  abi: "c", params: @[left], ret: integer, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Convert, dest: optionalValue, val: left),
      Instruction(kind: Opcode.Extract, dest: optionalPayload,
        val: optionalValue, field: "value")],
      term: Instruction(kind: Opcode.Return, value: optionalPayload))])
let optionalNone = Function(name: "foo_probe_optional_none", public: true,
  abi: "c", ret: boolean, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Construct, dest: optionalValue),
      Instruction(kind: Opcode.Extract, dest: optionalPresent,
        val: optionalValue, field: "present")],
      term: Instruction(kind: Opcode.Return, value: optionalPresent))])

let failableType = `Type`(kind: Shape.Failable, elem: integer)
let failableValue = reg("failable_value", failableType)
let failureFlag = reg("failure_flag", boolean)
let failableError = Function(name: "foo_probe_failable_error", public: true,
  abi: "c", ret: boolean, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Construct, op: "error", dest: failableValue,
        args: @[Value(kind: Flavor.Const, name: "SampleError",
          `type`: `Type`(kind: Shape.Error))]),
      Instruction(kind: Opcode.Extract, dest: failureFlag,
        val: failableValue, field: "failed")],
      term: Instruction(kind: Opcode.Return, value: failureFlag))])
let failableSuccess = Function(name: "foo_probe_failable_success", public: true,
  abi: "c", params: @[left], ret: boolean, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Convert, dest: failableValue, val: left),
      Instruction(kind: Opcode.Extract, dest: failureFlag,
        val: failableValue, field: "failed")],
      term: Instruction(kind: Opcode.Return, value: failureFlag))])
let tryValue = reg("try_value", integer)
let tryResult = reg("try_result", failableType)
let deferredTrace = Instruction(kind: Opcode.Defer,
  fallback: Block(label: "cleanup", instrs: @[
    Instruction(kind: Opcode.Trace, trace: "qbe-cleanup")]))
let trySuccess = Function(name: "foo_probe_try_success", public: true,
  abi: "c", params: @[left], ret: failableType,
  blocks: @[Block(label: "entry", instrs: @[
    deferredTrace,
    Instruction(kind: Opcode.Convert, dest: failableValue, val: left),
    Instruction(kind: Opcode.Try, dest: tryValue, expr: failableValue),
    Instruction(kind: Opcode.Convert, dest: tryResult, val: tryValue)],
    term: Instruction(kind: Opcode.Return, value: tryResult))])
let tryFailure = Function(name: "foo_probe_try_failure", public: true,
  abi: "c", ret: failableType,
  blocks: @[Block(label: "entry", instrs: @[
    deferredTrace,
    Instruction(kind: Opcode.Construct, op: "error", dest: failableValue,
      args: @[Value(kind: Flavor.Const, name: "SampleError",
        `type`: `Type`(kind: Shape.Error))]),
    Instruction(kind: Opcode.Try, dest: tryValue, expr: failableValue),
    Instruction(kind: Opcode.Convert, dest: tryResult, val: tryValue)],
    term: Instruction(kind: Opcode.Return, value: tryResult))])
let catchFallback = Block(label: "fallback", term: Instruction(
  kind: Opcode.Return, value: Value(kind: Flavor.Const,
    name: "7", `type`: integer)))
let catchFailure = Function(name: "foo_probe_catch_failure", public: true,
  abi: "c", ret: integer, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, op: "error", dest: failableValue,
      args: @[Value(kind: Flavor.Const, name: "SampleError",
        `type`: `Type`(kind: Shape.Error))]),
    Instruction(kind: Opcode.Catch, dest: tryValue,
      val: failableValue, fallback: catchFallback)],
    term: Instruction(kind: Opcode.Return, value: tryValue))])
let catchSuccess = Function(name: "foo_probe_catch_success", public: true,
  abi: "c", params: @[left], ret: integer,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Convert, dest: failableValue, val: left),
    Instruction(kind: Opcode.Catch, dest: tryValue,
      val: failableValue, fallback: catchFallback)],
    term: Instruction(kind: Opcode.Return, value: tryValue))])

let sliceType = `Type`(kind: Shape.Slice, elem: integer)
let sliceValue = reg("slice_value", sliceType)
let sliceItem = reg("slice_item", integer)
let sliceLength = reg("slice_length", unsignedWide)
let sliced = Function(name: "foo_probe_slice_index", public: true,
  abi: "c", params: @[arrayIndex], ret: integer, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Construct, op: "sequence", dest: sliceValue,
        args: items),
      Instruction(kind: Opcode.Index, dest: sliceItem,
        val: sliceValue, val2: arrayIndex)],
      term: Instruction(kind: Opcode.Return, value: sliceItem))])
let sliceSize = Function(name: "foo_probe_slice_length", public: true,
  abi: "c", ret: unsignedWide, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Construct, op: "sequence", dest: sliceValue,
        args: items),
      Instruction(kind: Opcode.Length, dest: sliceLength, val: sliceValue)],
      term: Instruction(kind: Opcode.Return, value: sliceLength))])

let byteType = `Type`(kind: Shape.Uint, width: 8)
let textType = `Type`(kind: Shape.Slice, elem: byteType, constant: true)
let textValue = Value(kind: Flavor.Const, name: "\"A\\x00B\"", `type`: textType)
let byteValue = reg("byte_value", byteType)
let byteIndex = Value(kind: Flavor.Const, name: "2", `type`: unsigned)
let textIndex = Function(name: "foo_probe_text_index", public: true,
  abi: "c", ret: byteType, blocks: @[
    Block(label: "entry", instrs: @[Instruction(kind: Opcode.Index,
      dest: byteValue, val: textValue, val2: byteIndex)],
      term: Instruction(kind: Opcode.Return, value: byteValue))])
let embeddedValue = reg("embedded_value", textType)
let embeddedLength = reg("embedded_length", unsignedWide)
let embedded = Function(name: "foo_probe_embedded_length", public: true,
  abi: "c", ret: unsignedWide, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Embed, dest: embeddedValue, path: "embed.txt",
        span: Location(file: "test/backend/qbe/emitter.nim")),
      Instruction(kind: Opcode.Length, dest: embeddedLength,
        val: embeddedValue)],
      term: Instruction(kind: Opcode.Return, value: embeddedLength))])

let mutableBytes = `Type`(kind: Shape.Slice, elem: byteType)
let allocationResult = `Type`(kind: Shape.Failable, elem: mutableBytes)
let allocationValue = reg("allocation_value", allocationResult)
let allocationFailed = reg("allocation_failed", boolean)
let allocationSize = reg("allocation_size", integer)
let allocationCount = reg("allocation_count", unsigned)
let allocationSlice = reg("allocation_slice", mutableBytes)
let allocationLength = reg("allocation_length", unsignedWide)
let reserveFailed = Function(name: "foo_probe_reserve_failed", public: true,
  abi: "c", params: @[allocationSize], ret: boolean,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Region, op: "open", region: "arena"),
    Instruction(kind: Opcode.Allocate, region: "arena",
      dest: allocationValue, val: allocationSize),
    Instruction(kind: Opcode.Extract, dest: allocationFailed,
      val: allocationValue, field: "failed"),
    Instruction(kind: Opcode.Region, op: "close", region: "arena")],
    term: Instruction(kind: Opcode.Return, value: allocationFailed))])
let reserveLength = Function(name: "foo_probe_reserve_length", public: true,
  abi: "c", params: @[allocationCount], ret: unsignedWide,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Region, op: "open", region: "arena"),
    Instruction(kind: Opcode.Allocate, region: "arena",
      dest: allocationValue, val: allocationCount),
    Instruction(kind: Opcode.Extract, dest: allocationSlice,
      val: allocationValue, field: "value"),
    Instruction(kind: Opcode.Length, dest: allocationLength,
      val: allocationSlice),
    Instruction(kind: Opcode.Region, op: "close", region: "arena")],
    term: Instruction(kind: Opcode.Return, value: allocationLength))])

var reflectionFields = initOrderedTable[string, `Type`]()
reflectionFields["size"] = unsignedWide
reflectionFields["alignment"] = unsignedWide
let reflectionType = `Type`(kind: Shape.Struct, fields: reflectionFields)
let reflectionValue = reg("reflection_value", reflectionType)
let reflectedSize = reg("reflected_size", unsignedWide)
let reflectedAlignment = reg("reflected_alignment", unsignedWide)
let reflectedSum = reg("reflected_sum", unsignedWide)
let reflect = Function(name: "foo_probe_reflect", public: true, abi: "c",
  ret: unsignedWide, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Reflect, dest: reflectionValue,
      argument: integer),
    Instruction(kind: Opcode.Extract, dest: reflectedSize,
      val: reflectionValue, field: "size"),
    Instruction(kind: Opcode.Extract, dest: reflectedAlignment,
      val: reflectionValue, field: "alignment"),
    Instruction(kind: Opcode.Add, dest: reflectedSum,
      val: reflectedSize, val2: reflectedAlignment)],
    term: Instruction(kind: Opcode.Return, value: reflectedSum))])

let vectorType = `Type`(kind: Shape.Vector, elem: integer, width: 4)
let maskType = `Type`(kind: Shape.Vector, elem: boolean, width: 4)
let vectorA = reg("vector_a", vectorType)
let vectorB = reg("vector_b", vectorType)
let vectorResult = reg("vector_result", vectorType)
let vectorMask = reg("vector_mask", maskType)
let vectorItem = reg("vector_item", integer)
let vectorConstants = @[11, 22, 33, 44]
let otherConstants = @[55, 66, 77, 88]
var vectorItems, otherItems: seq[Value]
for number in vectorConstants:
  vectorItems.add(Value(kind: Flavor.Const, name: $number, `type`: integer))
for number in otherConstants:
  otherItems.add(Value(kind: Flavor.Const, name: $number, `type`: integer))
let laneThree = Value(kind: Flavor.Const, name: "3", `type`: unsigned)
let laneTwo = Value(kind: Flavor.Const, name: "2", `type`: unsigned)
let laneOne = Value(kind: Flavor.Const, name: "1", `type`: unsigned)
let splat = Function(name: "foo_probe_splat", public: true, abi: "c",
  params: @[left], ret: integer, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Splat, dest: vectorResult, val: left),
    Instruction(kind: Opcode.Index, dest: vectorItem,
      val: vectorResult, val2: laneThree)],
    term: Instruction(kind: Opcode.Return, value: vectorItem))])
let shuffle = Function(name: "foo_probe_shuffle", public: true, abi: "c",
  ret: integer, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, dest: vectorA, args: vectorItems),
    Instruction(kind: Opcode.Construct, dest: vectorB, args: otherItems),
    Instruction(kind: Opcode.Shuffle, dest: vectorResult,
      val: vectorA, val2: vectorB, mask: @[3, 0, 5, 2]),
    Instruction(kind: Opcode.Index, dest: vectorItem,
      val: vectorResult, val2: laneTwo)],
    term: Instruction(kind: Opcode.Return, value: vectorItem))])
let selectVector = Function(name: "foo_probe_select_vector", public: true,
  abi: "c", ret: integer, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, dest: vectorA, args: vectorItems),
    Instruction(kind: Opcode.Construct, dest: vectorB, args: otherItems),
    Instruction(kind: Opcode.Construct, dest: vectorMask,
      args: @[Value(kind: Flavor.Const, name: "true", `type`: boolean),
        Value(kind: Flavor.Const, name: "false", `type`: boolean),
        Value(kind: Flavor.Const, name: "true", `type`: boolean),
        Value(kind: Flavor.Const, name: "false", `type`: boolean)]),
    Instruction(kind: Opcode.Select, dest: vectorResult,
      cond: vectorMask, val: vectorA, val2: vectorB),
    Instruction(kind: Opcode.Index, dest: vectorItem,
      val: vectorResult, val2: laneOne)],
    term: Instruction(kind: Opcode.Return, value: vectorItem))])
let twoVectorType = `Type`(kind: Shape.Vector, elem: integer, width: 2)
let indexVectorType = `Type`(kind: Shape.Vector, elem: unsigned, width: 2)
let vectorIndices = reg("vector_indices", indexVectorType)
let twoVectorResult = reg("two_vector_result", twoVectorType)
let vectorUpdates = reg("vector_updates", twoVectorType)
let gatherVector = Function(name: "foo_probe_gather_vector", public: true,
  abi: "c", ret: integer, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, dest: vectorA, args: vectorItems),
    Instruction(kind: Opcode.Construct, dest: vectorIndices,
      args: @[laneThree, Value(kind: Flavor.Const, name: "0", `type`: unsigned)]),
    Instruction(kind: Opcode.Gather, dest: twoVectorResult,
      val: vectorA, val2: vectorIndices),
    Instruction(kind: Opcode.Index, dest: vectorItem,
      val: twoVectorResult, val2: laneOne)],
    term: Instruction(kind: Opcode.Return, value: vectorItem))])
let dynamicIndex = reg("dynamic_index", unsigned)
let checkedGather = Function(name: "foo_probe_checked_gather", public: true,
  abi: "c", params: @[dynamicIndex], ret: integer,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, dest: vectorA, args: vectorItems),
    Instruction(kind: Opcode.Construct, dest: vectorIndices,
      args: @[dynamicIndex,
        Value(kind: Flavor.Const, name: "0", `type`: unsigned)]),
    Instruction(kind: Opcode.Gather, dest: twoVectorResult,
      val: vectorA, val2: vectorIndices),
    Instruction(kind: Opcode.Index, dest: vectorItem,
      val: twoVectorResult,
      val2: Value(kind: Flavor.Const, name: "0", `type`: unsigned))],
    term: Instruction(kind: Opcode.Return, value: vectorItem))])
let scatterVector = Function(name: "foo_probe_scatter_vector", public: true,
  abi: "c", ret: integer, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, dest: vectorA, args: vectorItems),
    Instruction(kind: Opcode.Construct, dest: vectorIndices,
      args: @[laneOne, laneOne]),
    Instruction(kind: Opcode.Construct, dest: vectorUpdates,
      args: @[otherItems[0], otherItems[1]]),
    Instruction(kind: Opcode.Scatter, dest: vectorResult,
      val: vectorA, val2: vectorIndices, args: @[vectorUpdates]),
    Instruction(kind: Opcode.Index, dest: vectorItem,
      val: vectorResult, val2: laneOne)],
    term: Instruction(kind: Opcode.Return, value: vectorItem))])
let vectorComparison = Function(name: "foo_probe_compare_vector", public: true,
  abi: "c", ret: boolean, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, dest: vectorA, args: vectorItems),
    Instruction(kind: Opcode.Construct, dest: vectorB,
      args: @[vectorItems[1], vectorItems[1], vectorItems[1], vectorItems[1]]),
    Instruction(kind: Opcode.Compare, op: "is less than",
      dest: vectorMask, val: vectorA, val2: vectorB),
    Instruction(kind: Opcode.Index, dest: reg("first_comparison", boolean),
      val: vectorMask,
      val2: Value(kind: Flavor.Const, name: "0", `type`: unsigned))],
    term: Instruction(kind: Opcode.Return,
      value: reg("first_comparison", boolean)))])
proc vectorReduction(name, operation: string): Function =
  Function(name: name, public: true, abi: "c", ret: integer,
    blocks: @[Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Construct, dest: vectorA, args: vectorItems),
      Instruction(kind: Opcode.Reduce, dest: vectorItem,
        val: vectorA, reduction: operation)],
      term: Instruction(kind: Opcode.Return, value: vectorItem))])
let wideVector = `Type`(kind: Shape.Vector, elem: unsignedWide, width: 2)
let wideItems = reg("wide_items", wideVector)
let wideResult = reg("wide_result", unsignedWide)
let overflowingReduction = Function(name: "foo_probe_reduce_overflow",
  public: true, abi: "c", ret: unsignedWide,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, dest: wideItems, args: @[
      Value(kind: Flavor.Const, name: "18446744073709551615",
        `type`: unsignedWide),
      Value(kind: Flavor.Const, name: "2", `type`: unsignedWide)]),
    Instruction(kind: Opcode.Reduce, dest: wideResult,
      val: wideItems, reduction: "Add")],
    term: Instruction(kind: Opcode.Return, value: wideResult))])
let floatVector = `Type`(kind: Shape.Vector, elem: decimal, width: 2)
let floatItems = reg("float_items", floatVector)
let floatResult = reg("float_result", decimal)
let floatReduction = Function(name: "foo_probe_reduce_float", public: true,
  abi: "c", ret: decimal, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, dest: floatItems, args: @[
      Value(kind: Flavor.Const, name: "1.25", `type`: decimal),
      Value(kind: Flavor.Const, name: "2.5", `type`: decimal)]),
    Instruction(kind: Opcode.Reduce, dest: floatResult,
      val: floatItems, reduction: "Add")],
    term: Instruction(kind: Opcode.Return, value: floatResult))])
let atomic32 = `Type`(kind: Shape.Int, width: 32,
  attributes: @["atomic"])
let atomic32Pointer = reg("atomic32_pointer",
  `Type`(kind: Shape.Ptr, elem: atomic32))
let atomicDelta = reg("atomic_delta", integer)
let atomicOld = reg("atomic_old", integer)
let atomicAdd = Function(name: "foo_probe_atomic_add32", public: true,
  abi: "c", params: @[atomic32Pointer, atomicDelta], ret: integer,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Atomic, op: "add", field: "acq_rel",
      `ptr`: atomic32Pointer, val: atomicDelta, dest: atomicOld)],
    term: Instruction(kind: Opcode.Return, value: atomicOld))])
let atomic8 = `Type`(kind: Shape.Uint, width: 8,
  attributes: @["atomic"])
let atomic8Pointer = reg("atomic8_pointer",
  `Type`(kind: Shape.Ptr, elem: atomic8))
let atomicByte = reg("atomic_byte", byteType)
let atomicByteOld = reg("atomic_byte_old", byteType)
let atomicSwap = Function(name: "foo_probe_atomic_swap8", public: true,
  abi: "c", params: @[atomic8Pointer, atomicByte], ret: byteType,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Atomic, op: "swap", field: "seq_cst",
      `ptr`: atomic8Pointer, val: atomicByte, dest: atomicByteOld)],
    term: Instruction(kind: Opcode.Return, value: atomicByteOld))])
let atomic64 = `Type`(kind: Shape.Uint, width: 64,
  attributes: @["atomic"])
let atomic64Pointer = reg("atomic64_pointer",
  `Type`(kind: Shape.Ptr, elem: atomic64))
let atomic64Input = reg("atomic64_input", unsignedWide)
let atomic64Output = reg("atomic64_output", unsignedWide)
let atomicRoundTrip = Function(name: "foo_probe_atomic_roundtrip64",
  public: true, abi: "c", params: @[atomic64Pointer, atomic64Input],
  ret: unsignedWide, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Atomic, op: "store", field: "release",
      `ptr`: atomic64Pointer, val: atomic64Input),
    Instruction(kind: Opcode.Atomic, op: "fence", field: "seq_cst"),
    Instruction(kind: Opcode.Atomic, op: "load", field: "acquire",
      `ptr`: atomic64Pointer, dest: atomic64Output)],
    term: Instruction(kind: Opcode.Return, value: atomic64Output))])

let compared = reg("compared", boolean)
let less = Function(name: "foo_probe_less", public: true, abi: "c",
  params: @[left, right], ret: boolean, blocks: @[
    Block(label: "entry", instrs: @[Instruction(kind: Opcode.Compare,
      op: "is less than", dest: compared, val: left, val2: right)],
      term: Instruction(kind: Opcode.Return, value: compared))])

let counter = Value(kind: Flavor.Global, name: "counter", `type`: pointer)
let current = reg("current", wide)
let readCounter = Function(name: "foo_probe_read_counter", public: true,
  abi: "c", ret: wide, blocks: @[Block(label: "entry",
    instrs: @[Instruction(kind: Opcode.Load, `ptr`: counter, dest: current)],
    term: Instruction(kind: Opcode.Return, value: current))])
let writeCounter = Function(name: "foo_probe_write_counter", public: true,
  abi: "c", params: @[input], ret: `Type`(kind: Shape.Void), blocks: @[
    Block(label: "entry", instrs: @[Instruction(kind: Opcode.Store,
      `ptr`: counter, val: input)], term: Instruction(kind: Opcode.Return))])
let flag = Value(kind: Flavor.Global, name: "flag",
  `type`: `Type`(kind: Shape.Ptr, elem: boolean))
let flagValue = reg("flag_value", boolean)
let readFlag = Function(name: "foo_probe_read_flag", public: true,
  abi: "c", ret: boolean, blocks: @[Block(label: "entry",
    instrs: @[Instruction(kind: Opcode.Load, `ptr`: flag, dest: flagValue)],
    term: Instruction(kind: Opcode.Return, value: flagValue))])
let ratio = Value(kind: Flavor.Global, name: "ratio",
  `type`: `Type`(kind: Shape.Ptr, elem: decimal))
let ratioValue = reg("ratio_value", decimal)
let readRatio = Function(name: "foo_probe_read_ratio", public: true,
  abi: "c", ret: decimal, blocks: @[Block(label: "entry",
    instrs: @[Instruction(kind: Opcode.Load, `ptr`: ratio, dest: ratioValue)],
    term: Instruction(kind: Opcode.Return, value: ratioValue))])

proc bitFunction(name, operation: string; t: `Type`): Function =
  let lhs = reg("lhs", t)
  let rhs = reg("rhs", t)
  let output = reg("output", t)
  Function(name: name, public: true, abi: "c",
    params: (if operation == "not": @[lhs] else: @[lhs, rhs]), ret: t,
    blocks: @[Block(label: "entry", instrs: @[Instruction(kind: Opcode.Bit,
      op: operation, dest: output, val: lhs,
      val2: (if operation == "not": Value() else: rhs))],
      term: Instruction(kind: Opcode.Return, value: output))])

proc convertFunction(name: string; source, target: `Type`): Function =
  let input = reg("source", source)
  let output = reg("output", target)
  Function(name: name, public: true, abi: "c", params: @[input], ret: target,
    blocks: @[Block(label: "entry", instrs: @[Instruction(
      kind: Opcode.Convert, dest: output, val: input)],
      term: Instruction(kind: Opcode.Return, value: output))])

proc arithmeticFunction(name: string; operation: Opcode; t: `Type`): Function =
  let lhs = reg("lhs", t)
  let rhs = reg("rhs", t)
  let output = reg("output", t)
  Function(name: name, public: true, abi: "c", params: @[lhs, rhs], ret: t,
    blocks: @[Block(label: "entry", instrs: @[Instruction(kind: operation,
      dest: output, val: lhs, val2: rhs)],
      term: Instruction(kind: Opcode.Return, value: output))])

let signedFloat = convertFunction("foo_probe_signed_float", integer, decimal)
let unsignedFloat = convertFunction("foo_probe_unsigned_float", unsigned, decimal)
let floatWiden = convertFunction("foo_probe_float_widen", single, decimal)
let signedWiden = convertFunction("foo_probe_signed_widen", integer, wide)
let unsignedWiden = convertFunction("foo_probe_unsigned_widen", unsigned, unsignedWide)
let unsignedToSigned = convertFunction("foo_probe_unsigned_to_signed", unsigned, wide)

let phiValue = reg("phi_value", integer)
let explicitPhi = Function(name: "foo_probe_explicit_phi", public: true,
  abi: "c", params: @[condition, left, right], ret: integer, blocks: @[
    Block(label: "entry", term: Instruction(kind: Opcode.Cjump,
      cond: condition, yes: "yes", no: "no")),
    Block(label: "yes", term: Instruction(kind: Opcode.Jump, label: "merge")),
    Block(label: "no", term: Instruction(kind: Opcode.Jump, label: "merge")),
    Block(label: "merge", instrs: @[Instruction(kind: Opcode.Phi,
      dest: phiValue, blocks: @[(label: "yes", value: left),
        (label: "no", value: right)])],
      term: Instruction(kind: Opcode.Return, value: phiValue))])

let loopValue = reg("loop_value", unsigned)
let toggled = reg("toggled", unsigned)
let loopCondition = reg("loop_condition", boolean)
let zero = Value(kind: Flavor.Const, name: "0", `type`: unsigned)
let one = Value(kind: Flavor.Const, name: "1", `type`: unsigned)
let loopPhi = Function(name: "foo_probe_loop_phi", public: true,
  abi: "c", ret: unsigned, blocks: @[
    Block(label: "entry", term: Instruction(kind: Opcode.Jump, label: "loop")),
    Block(label: "loop", instrs: @[
      Instruction(kind: Opcode.Phi, dest: loopValue,
        blocks: @[(label: "entry", value: zero),
          (label: "body", value: toggled)]),
      Instruction(kind: Opcode.Compare, op: "is less than", dest: loopCondition,
        val: loopValue, val2: one)],
      term: Instruction(kind: Opcode.Cjump, cond: loopCondition,
        yes: "body", no: "done")),
    Block(label: "body", instrs: @[Instruction(kind: Opcode.Bit,
      op: "xor", dest: toggled, val: loopValue, val2: one)],
      term: Instruction(kind: Opcode.Jump, label: "loop")),
    Block(label: "done", term: Instruction(kind: Opcode.Return,
      value: loopValue))])

let checkedResult = reg("checked_result", integer)
let checkedValue = reg("checked_value", integer)
let guardedPhi = Function(name: "foo_probe_guarded_phi", public: true,
  abi: "c", params: @[condition, left], ret: integer, blocks: @[
    Block(label: "entry", term: Instruction(kind: Opcode.Cjump,
      cond: condition, yes: "checked", no: "plain")),
    Block(label: "checked", instrs: @[Instruction(kind: Opcode.Add,
      dest: checkedValue, val: left, val2: Value(kind: Flavor.Const,
        name: "1", `type`: integer))],
      term: Instruction(kind: Opcode.Jump, label: "merge")),
    Block(label: "plain", term: Instruction(kind: Opcode.Jump,
      label: "merge")),
    Block(label: "merge", instrs: @[Instruction(kind: Opcode.Phi,
      dest: checkedResult, blocks: @[(label: "checked", value: checkedValue),
        (label: "plain", value: left)])],
      term: Instruction(kind: Opcode.Return, value: checkedResult))])

let indexedBase = reg("indexed_base", pointer)
let indexedPosition = reg("indexed_position", integer)
let indexedValue = reg("indexed_value", wide)
let indexedAddress = reg("indexed_address", pointer)
let pointerRead = Function(name: "foo_probe_pointer_read", public: true,
  abi: "c", params: @[indexedBase, indexedPosition], ret: wide,
  blocks: @[Block(label: "entry", instrs: @[Instruction(kind: Opcode.Index,
    op: "value", dest: indexedValue, val: indexedBase,
    val2: indexedPosition)], term: Instruction(kind: Opcode.Return,
    value: indexedValue))])
let pointerAddress = Function(name: "foo_probe_pointer_address", public: true,
  abi: "c", params: @[indexedBase, indexedPosition], ret: pointer,
  blocks: @[Block(label: "entry", instrs: @[Instruction(kind: Opcode.Index,
    op: "address", dest: indexedAddress, val: indexedBase,
    val2: indexedPosition)], term: Instruction(kind: Opcode.Return,
    value: indexedAddress))])
let alignedPointer = reg("aligned_pointer", `Type`(kind: Shape.Ptr,
  elem: pointer))
let alignmentValue = reg("alignment_value", unsignedWide)
let alignmentChecked = Function(name: "foo_probe_align", public: true,
  abi: "c", params: @[alignedPointer, alignmentValue], ret: boolean,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Native, op: "machine:align",
      args: @[alignedPointer, alignmentValue])],
    term: Instruction(kind: Opcode.Return, value: Value(
      kind: Flavor.Const, name: "true", `type`: boolean)))])

let sample = Module(funcs: @[choose, add, memory, invoke, indirect,
    globalCallback, traced, panicked, recordRead, recordAddress,
    mixedIdentity, mixedExternal, largeIdentity,
    indexed, length, optionalSome, optionalNone, failableError,
    failableSuccess, trySuccess, tryFailure, catchFailure, catchSuccess,
    sliced, sliceSize, textIndex, embedded,
    reserveFailed, reserveLength, reflect,
    splat, shuffle, selectVector, gatherVector, checkedGather, scatterVector,
    vectorComparison,
    vectorReduction("foo_probe_reduce_add", ""),
    vectorReduction("foo_probe_reduce_mul", "Mul"),
    vectorReduction("foo_probe_reduce_min", "Min"),
    vectorReduction("foo_probe_reduce_max", "Max"),
    vectorReduction("foo_probe_reduce_and", "And"),
    vectorReduction("foo_probe_reduce_or", "Or"),
    vectorReduction("foo_probe_reduce_xor", "Xor"),
    overflowingReduction, floatReduction, atomicAdd, atomicSwap,
    atomicRoundTrip, less,
    readCounter, writeCounter, readFlag, readRatio,
    bitFunction("foo_probe_bit_and", "and", unsigned),
    bitFunction("foo_probe_bit_or", "or", unsigned),
    bitFunction("foo_probe_bit_xor", "xor", unsignedWide),
    bitFunction("foo_probe_bit_not", "not", unsignedWide),
    bitFunction("foo_probe_shift_left", "shl", unsigned),
    bitFunction("foo_probe_shift_right", "lshr", unsignedWide),
    bitFunction("foo_probe_shift_arithmetic", "ashr", wide),
    bitFunction("foo_probe_bit_set", "set", unsigned),
    bitFunction("foo_probe_bit_clear", "clear", unsigned),
    bitFunction("foo_probe_bit_toggle", "toggle", unsigned),
    arithmeticFunction("foo_probe_signed_add", Opcode.Add, integer),
    arithmeticFunction("foo_probe_unsigned_add", Opcode.Add, unsignedWide),
    arithmeticFunction("foo_probe_signed_sub", Opcode.Sub, wide),
    arithmeticFunction("foo_probe_unsigned_sub", Opcode.Sub, unsigned),
    arithmeticFunction("foo_probe_signed_mul", Opcode.Mul, integer),
    arithmeticFunction("foo_probe_unsigned_mul", Opcode.Mul, unsigned),
    arithmeticFunction("foo_probe_signed_mul64", Opcode.Mul, wide),
    arithmeticFunction("foo_probe_unsigned_mul64", Opcode.Mul, unsignedWide),
    arithmeticFunction("foo_probe_signed_div", Opcode.Div, wide),
    arithmeticFunction("foo_probe_unsigned_div", Opcode.Div, unsignedWide),
    arithmeticFunction("foo_probe_signed_rem", Opcode.Remainder, wide),
    arithmeticFunction("foo_probe_unsigned_rem", Opcode.Remainder, unsigned),
    signedFloat, unsignedFloat, floatWiden, signedWiden, unsignedWiden,
    unsignedToSigned, explicitPhi, loopPhi, guardedPhi, pointerRead,
    pointerAddress, alignmentChecked], storage: @[
    Storage(name: "counter", public: true, value: Value(kind: Flavor.Const,
      name: "17", `type`: wide)),
    Storage(name: "signed32", value: Value(kind: Flavor.Const,
      name: "-123", `type`: integer)),
    Storage(name: "unsigned32", value: Value(kind: Flavor.Const,
      name: "4294967295", `type`: `Type`(kind: Shape.Uint, width: 32))),
    Storage(name: "unsigned64", value: Value(kind: Flavor.Const,
      name: "18446744073709551615", `type`: `Type`(kind: Shape.Uint, width: 64))),
    Storage(name: "flag", value: Value(kind: Flavor.Const,
      name: "true", `type`: boolean)),
    Storage(name: "single", value: Value(kind: Flavor.Const,
      name: "1.5", `type`: `Type`(kind: Shape.Float, width: 32))),
    Storage(name: "ratio", value: Value(kind: Flavor.Const,
      name: "1.25", `type`: decimal))],
  externs: @[Extern(name: "twice", symbol: "foo_probe_twice", abi: "c",
    params: @[integer], ret: integer),
    Extern(name: "advance_mixed", symbol: "foo_probe_advance_mixed",
      abi: "c", params: @[mixedType], ret: mixedType)])
let il = emit(sample)
doAssert "export data $storage.counter = align 8 { l 17 }" in il
doAssert "export data $storage.unsigned64 = align 8 { l 18446744073709551615 }" in il
doAssert "export data $storage.flag = align 1 { b 1 }" in il
doAssert "export data $storage.single = align 4 { s s_1.5 }" in il
doAssert "export data $storage.ratio = align 8 { d d_1.25 }" in il
doAssert "loadl $storage.counter" in il
doAssert "storel %input, $storage.counter" in il
doAssert "phi @qbe.edge." in il
doAssert "csltw %left, %right" in il
doAssert "call $foo_probe_twice(w %left)" in il
doAssert "call %callback(w %left)" in il
doAssert "ret $foo_probe_twice" in il
doAssert "call $foo_qbe_trace" in il
doAssert "call $foo_qbe_panic(l $qbe.text." in il
doAssert "type :qbe.abi." in il
doAssert "call $foo_probe_advance_mixed(:qbe.abi." in il
doAssert "blit $qbe.zero.8, %record_value, 8" in il
doAssert "blit $qbe.zero.12, %array_value, 12" in il
doAssert "qbe_error_IndexOutOfBounds" in il
doAssert "=w cnel" in il
doAssert "SampleError" notin il
doAssert "data $qbe.bytes." in il
doAssert "data $qbe.slice." in il
doAssert "alloc8 8" in il
doAssert "=w and %lhs, %rhs" in il
doAssert "=l xor %lhs, -1" in il
doAssert "=d swtof %source" in il
doAssert "=d uwtof %source" in il
doAssert "=d exts %source" in il
doAssert "=l extsw %source" in il
doAssert "=l extuw %source" in il
doAssert "=w phi @qbe.edge." in il
doAssert "@qbe.edge." in il
doAssert "=l mul %qbe.check." in il
doAssert "qbe_error_IntegerOverflow" in il
doAssert "qbe_error_ShiftOutOfBounds" in il
doAssert "qbe_error_DivisionByZero" in il
doAssert "call $foo_qbe_panic" in il
doAssert "call $foo_qbe_reserve" in il
doAssert "call $foo_qbe_atomic_add32" in il
doAssert "call $foo_qbe_atomic_fence" in il
doAssert "qbe_error_InvalidAlignment" in il
doAssert "qbe.issue.bad." in il
doAssert "qbe.cleanup.run." in il
doAssert "call $foo_qbe_free(l %qbe.region." in il
let output = getEnv("FOO_QBE_OUTPUT")
if output.len > 0: writeFile(output, il)

let syscallResult = reg("syscall_result", wide)
let syscall = Function(name: "foo_probe_linux_getpid", public: true,
  abi: "c", ret: wide, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Native, op: "machine:system",
      dest: syscallResult, args: @[Value(kind: Flavor.Const,
        name: "39", `type`: wide)])],
    term: Instruction(kind: Opcode.Return, value: syscallResult))])
let nativeModule = Module(funcs: @[syscall])
let nativeIl = emit(nativeModule, target = "linux-x64")
doAssert "call $foo_qbe_syscall6(l 39" in nativeIl
try:
  discard emit(nativeModule, target = "windows-x64")
  doAssert false, "Linux syscall must reject Windows target"
except ValueError as error:
  doAssert "system call target" in error.msg
let nativeOutput = getEnv("FOO_QBE_NATIVE_OUTPUT")
if nativeOutput.len > 0: writeFile(nativeOutput, nativeIl)

let outOfRange = Module(funcs: @[Function(name: "bad_constant", abi: "c",
  ret: unsigned, blocks: @[Block(label: "entry", term: Instruction(
    kind: Opcode.Return, value: Value(kind: Flavor.Const,
      name: "4294967296", `type`: unsigned)))])])
try:
  discard emit(outOfRange)
  doAssert false, "out-of-range constants must be rejected"
except ValueError as error:
  doAssert "out-of-range" in error.msg

let atomic = `Type`(kind: Shape.Int, width: 32, attributes: @["atomic"])
let attributed = Module(funcs: @[Function(name: "bad_atomic", abi: "c",
  params: @[reg("value", atomic)], ret: atomic,
  blocks: @[Block(label: "entry", term: Instruction(kind: Opcode.Return,
    value: reg("value", atomic)))])])
try:
  discard emit(attributed)
  doAssert false, "atomic attributes must be rejected"
except ValueError as error:
  doAssert "attributed" in error.msg

for bad in [
    convertFunction("narrow_float", decimal, single),
    convertFunction("inexact_float", wide, decimal),
    convertFunction("signed_to_unsigned", integer, unsigned),
    convertFunction("unsigned_to_signed_same_width", unsigned, integer)]:
  try:
    discard emit(Module(funcs: @[bad]))
    doAssert false, "non-lossless conversion must be rejected"
  except ValueError as error:
    doAssert "conversion" in error.msg

try:
  discard emit(Module(funcs: @[bitFunction("bad_bit_op", "unknown", unsigned)]))
  doAssert false, "unknown bit operation must be rejected"
except ValueError as error:
  doAssert "bit operation" in error.msg

let missingPhiEdge = Function(name: "missing_phi_edge", abi: "c",
  params: @[condition, left], ret: integer, blocks: @[
    Block(label: "entry", term: Instruction(kind: Opcode.Cjump,
      cond: condition, yes: "yes", no: "no")),
    Block(label: "yes", term: Instruction(kind: Opcode.Jump, label: "merge")),
    Block(label: "no", term: Instruction(kind: Opcode.Jump, label: "merge")),
    Block(label: "merge", instrs: @[Instruction(kind: Opcode.Phi,
      dest: phiValue, blocks: @[(label: "yes", value: left)])],
      term: Instruction(kind: Opcode.Return, value: phiValue))])
try:
  discard emit(Module(funcs: @[missingPhiEdge]))
  doAssert false, "incomplete phi must be rejected"
except ValueError as error:
  doAssert "phi predecessor count" in error.msg

let missingGlobal = Module(funcs: @[readCounter])
try:
  discard emit(missingGlobal)
  doAssert false, "unknown global must be rejected"
except ValueError as error:
  doAssert "unknown or mismatched global" in error.msg

let wrongType = Module(funcs: @[readCounter], storage: @[
  Storage(name: "counter", value: Value(kind: Flavor.Const,
    name: "17", `type`: integer))])
try:
  discard emit(wrongType)
  doAssert false, "mismatched global pointer must be rejected"
except ValueError as error:
  doAssert "unknown or mismatched global" in error.msg

let mismatchedCallback = Value(kind: Flavor.Global, name: "twice",
  `type`: `Type`(kind: Shape.Function, abi: "c",
    params: @[wide], ret: integer))
let invalidCallback = Function(name: "invalid_callback", abi: "c",
  ret: mismatchedCallback.type, blocks: @[Block(label: "entry",
    term: Instruction(kind: Opcode.Return, value: mismatchedCallback))])
try:
  discard emit(Module(funcs: @[invalidCallback], externs: sample.externs))
  doAssert false, "callback signature mismatch must be rejected"
except ValueError as error:
  doAssert "mismatched external function" in error.msg

let invalidInitializer = Module(storage: @[Storage(name: "bad",
  value: Value(kind: Flavor.Const, name: "4294967296", `type`: unsigned))])
try:
  discard emit(invalidInitializer)
  doAssert false, "out-of-range initializer must be rejected"
except ValueError as error:
  doAssert "out-of-range" in error.msg

let atomicStorage = Module(storage: @[Storage(name: "atomic_flag",
  value: Value(kind: Flavor.Const, name: "true", `type`:
    `Type`(kind: Shape.Bool, attributes: @["atomic"])))])
try:
  discard emit(atomicStorage)
  doAssert false, "atomic storage must not become ordinary data"
except ValueError as error:
  doAssert "attributed" in error.msg

let escapedAllocation = Function(name: "escaped_allocation", abi: "c",
  ret: pointer, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Alloc, region: "scope", dest: slot)],
    term: Instruction(kind: Opcode.Return, value: slot))])
try:
  discard emit(Module(funcs: @[escapedAllocation]))
  doAssert false, "owned allocation may not escape through a return"
except ValueError as error:
  doAssert "escape owned memory" in error.msg

let emptyArray = `Type`(kind: Shape.Array, elem: integer, width: 0)
let emptyParameter = reg("empty", emptyArray)
let emptyBoundary = Function(name: "empty_boundary", abi: "c",
  params: @[emptyParameter], ret: integer, blocks: @[Block(label: "entry",
    term: Instruction(kind: Opcode.Return, value: left))])
try:
  discard emit(Module(funcs: @[emptyBoundary]))
  doAssert false, "zero-sized aggregate C ABI must be rejected"
except ValueError as error:
  doAssert "zero-sized aggregate C ABI" in error.msg

let attributedInstruction = Function(name: "attributed_instruction", abi: "c",
  params: @[left, right], ret: integer, blocks: @[Block(label: "entry",
    instrs: @[Instruction(kind: Opcode.Add, dest: reg("sum", integer),
      val: left, val2: right, attributes: @["special"])],
    term: Instruction(kind: Opcode.Return,
      value: reg("sum", integer)))])
let foreignCallAbi = Function(name: "foreign_call_abi", abi: "c",
  params: @[left], ret: integer, blocks: @[Block(label: "entry",
    instrs: @[Instruction(kind: Opcode.Call, `func`: "twice",
      args: @[left], dest: called, abi: "system")],
    term: Instruction(kind: Opcode.Return, value: called))])
let attributedTerminator = Function(name: "attributed_terminator", abi: "c",
  ret: integer, blocks: @[Block(label: "entry",
    term: Instruction(kind: Opcode.Return, value: left,
      attributes: @["special"]))])
for bad in [attributedInstruction, foreignCallAbi, attributedTerminator]:
  try:
    discard emit(Module(funcs: @[bad], externs: sample.externs))
    doAssert false, "unsupported instruction metadata must be rejected"
  except ValueError as error:
    doAssert "attributes" in error.msg or "ABI" in error.msg

echo "QBE emitter probe: ok"
