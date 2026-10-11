## Typed-IR supplements for fixed arrays, overlapping unions and cyclic merges.
## Source spelling/checking remains covered by core.nim and test/{types,ir}.
import std/[os, osproc, strutils, tables, json]
import ../../../src/ir/[node, kind, valid, print]
import ../../../src/backend/c/driver as cDriver
import ../../../src/backend/zig/driver as zigDriver
import ../../../src/backend/llvm/[driver, layout, runtime]
import ../../../src/build/options
import ../../../src/toolchain/manager

type Type = node.Type
let i9 = Type(kind: TypeKind.Int,width: 9)
let integer = Type(kind: TypeKind.Int,width: 64)
let boolean = Type(kind: TypeKind.Bool)
let nothing = Type(kind: TypeKind.Void)
proc reg(name: string;t: Type):Value = Value(kind: ValueKind.Reg,name: name,`type`: t)
proc number(n: string;t=integer):Value = Value(kind: ValueKind.Const,name: n,`type`: t)
proc returns(v=Value()):Instruction = Instruction(kind: InstrKind.Return,value: v)
proc compare(dest: Value;a,b: Value;op="equals"):Instruction =
  Instruction(kind: InstrKind.Compare,dest: dest,val: a,val2: b,op: op)
proc expect(value: Value):Instruction = Instruction(kind: InstrKind.Call,`func`: "expect",args: @[value])
proc program(name: string;body: seq[Instruction];helpers: seq[Function] = @[]):Module =
  result = Module(name: name,version: 1,stage: "@foo",requires: "system",funcs: helpers & @[
    Function(name: "main",ret: nothing,blocks: @[Block(label: "entry",instrs: body,term: returns())])],
    externs: @[Extern(name: "expect",symbol: "expect",abi: "runtime.testing",params: @[boolean],ret: nothing)])
  discard seal(result)

let arrayType = Type(kind: TypeKind.Array,elem: i9,width: 3)
let arrayValue=reg("array",arrayType); let element=reg("element",i9)
let length=reg("length",integer); let checked=reg("checked",boolean)
let checkedLength=reg("checked_length",boolean)
let arrays = program("arrays",@[
  Instruction(kind: InstrKind.Construct,dest: arrayValue,args: @[number("255",i9),number("-256",i9),number("0",i9)]),
  Instruction(kind: InstrKind.Index,dest: element,val: arrayValue,val2: number("1")),
  compare(checked,element,number("-256",i9)),expect(checked),
  Instruction(kind: InstrKind.Length,dest: length,val: arrayValue),
  compare(checkedLength,length,number("3")),expect(checkedLength)])

let overlay=Type(kind: TypeKind.ExternUnion,name: "Overlay")
overlay.fields["word"]=Type(kind: TypeKind.Uint,width: 32)
overlay.fields["byte"]=Type(kind: TypeKind.Uint,width: 8)
overlay.fields["signed"]=Type(kind: TypeKind.Int,width: 32)
doAssert measure(overlay).offsets == @[0,0,0]
let address=reg("cell",Type(kind: TypeKind.Ptr,elem: overlay))
let word=reg("word",Type(kind: TypeKind.Ptr,elem: overlay.fields["word"]))
let low=reg("low",overlay.fields["byte"]);let signed=reg("signed",overlay.fields["signed"])
let lowCheck=reg("low_check",boolean);let signedCheck=reg("signed_check",boolean)
let unions = program("union-layout",@[
  Instruction(kind: InstrKind.Alloc,op: "slot",region: "scope",dest: address),
  Instruction(kind: InstrKind.Extract,op: "address",dest: word,val: address,field: "word"),
  Instruction(kind: InstrKind.Store,`ptr`: word,val: number("305419896",overlay.fields["word"])),
  Instruction(kind: InstrKind.Extract,dest: low,val: address,field: "byte"),
  compare(lowCheck,low,number("120",overlay.fields["byte"])),expect(lowCheck),
  Instruction(kind: InstrKind.Extract,dest: signed,val: address,field: "signed"),
  compare(signedCheck,signed,number("305419896",overlay.fields["signed"])),expect(signedCheck)])
unions.types = @[TypeDecl(name: "Overlay",`type`: overlay)]
unions.regions = @[Region(id: "scope",kind: "scope")]

let a=reg("a",integer);let b=reg("b",integer);let count=reg("count",integer)
let next=reg("next",integer);let condition=reg("condition",boolean)
let first=reg("first",boolean);let second=reg("second",boolean)
let cyclic=Function(name: "cyclic",ret: integer,blocks: @[
  Block(label: "entry",term: Instruction(kind: InstrKind.Jump,label: "loop")),
  Block(label: "loop",instrs: @[
    Instruction(kind: InstrKind.Phi,dest: a,blocks: @[(label: "entry",value: number("1")),(label: "body",value: b)]),
    Instruction(kind: InstrKind.Phi,dest: b,blocks: @[(label: "entry",value: number("2")),(label: "body",value: a)]),
    Instruction(kind: InstrKind.Phi,dest: count,blocks: @[(label: "entry",value: number("0")),(label: "body",value: next)]),
    compare(condition,count,number("3"),"is less than")],
    term: Instruction(kind: InstrKind.Cjump,cond: condition,trueLabel: "body",falseLabel: "done")),
  Block(label: "body",instrs: @[Instruction(kind: InstrKind.Add,dest: next,val: count,val2: number("1"),panic: "overflow")],
    term: Instruction(kind: InstrKind.Jump,label: "loop")),
  Block(label: "done",instrs: @[compare(first,a,number("2")),expect(first),compare(second,b,number("1")),expect(second)],term: returns(count)),
  Block(label: "overflow",term: Instruction(kind: InstrKind.Panic,msg: "IntegerOverflow"))])
let answer=reg("answer",integer);let answerCheck=reg("answer_check",boolean)
let merges=program("cyclic-phi",@[Instruction(kind: InstrKind.Call,dest: answer,`func`: "cyclic"),
  compare(answerCheck,answer,number("3")),expect(answerCheck)],@[cyclic])

let root=absolutePath(getEnv("FOO_LLVM_IRROOT",".artifacts/llvm-ircore"))
let zig=detect().path
doAssert zig.len > 0,"All three backends are required"
var report=newJArray()
for module in [unions,merges,arrays]:
  let errors=validate(module)
  doAssert errors.len == 0, $errors
  for mode in ["dev","release"]:
    for backend in ["c","zig","llvm"]:
      let output=root/module.name/mode/backend
      createDir(output)
      writeFile(output/"input.json",encode(module))
      let options=Native(name: module.name,compile: true,compiler: "clang",level: "system")
      var artifact,error: string
      var success=false
      case backend
      of "c":
        let built=cDriver.build(module,mode,output,options)
        success=built.success;artifact=built.artifact;error=built.error
      of "zig":
        let built=zigDriver.build(module,mode,output,zig,"ircore.nim",options)
        success=built.success;artifact=built.artifact;error=built.error
      else:
        let built=driver.build(module,mode,output,options,"ircore.nim")
        success=built.success;artifact=built.artifact;error=built.error
      doAssert success,error
      let executed=execCmdEx(quoteShell(artifact))
      report.add(%*{"fixture":module.name,"mode":mode,"backend":backend,"exit":executed.exitCode,"bytes":executed.output.toHex()})
      writeFile(root/"results.json",pretty(report))
      doAssert executed.exitCode == 0 and executed.output.len == 0,$report[^1]
      echo module.name,"/",mode,"/",backend,": passed"

# A second merge representation accepted by the shared IR validator. Legacy
# emitters do not declare block parameters; require their concrete diagnostic.
let parameter=reg("block_parameter",integer)
let parameters=program("block-parameters",@[Instruction(kind: InstrKind.Call,dest: answer,`func`: "parameter"),
  compare(answerCheck,answer,number("42")),expect(answerCheck)],@[Function(name: "parameter",ret: integer,blocks: @[
  Block(label: "entry",term: Instruction(kind: InstrKind.Jump,label: "joined",args: @[number("42")])),
  Block(label: "joined",params: @[parameter],term: returns(parameter))])])
doAssert validate(parameters).len == 0
for mode in ["dev","release"]:
  let options=Native(name: "parameters",compile: true,compiler: "clang")
  for backend in ["c","zig"]:
    let output=root/"block-parameters"/mode/backend
    var success: bool
    var error: string
    if backend == "c":
      let built=cDriver.build(parameters,mode,output,options)
      success=built.success;error=built.error
    else:
      let built=zigDriver.build(parameters,mode,output,zig,"ircore.nim",options)
      success=built.success;error=built.error
    let missingParameter = if backend == "c": "foo_symbol_block_f_parameter" else: "v_block_parameter"
    doAssert not success and error.contains(missingParameter),error
    report.add(%*{"fixture":"block-parameters","mode":mode,"backend":backend,
      "unsupported":true,"reason":"The legacy emitter does not declare typed block parameters", "error":error})
  let built=driver.build(parameters,mode,root/"block-parameters"/mode/"llvm",options)
  doAssert built.success,built.error
  let executed=execCmdEx(quoteShell(built.artifact))
  doAssert executed.exitCode == 0 and executed.output.len == 0,executed.output
  report.add(%*{"fixture":"block-parameters","mode":mode,"backend":"llvm","exit":executed.exitCode,"bytes":executed.output.toHex()})
  writeFile(root/"results.json",pretty(report))

# Known foreign conventions and aggregate callbacks are exercised by ffi.nim.
# Unknown conventions must still produce an actionable failure.
let foreign=program("foreign-entry",@[],@[Function(name: "foreign",abi: "unknown",ret: nothing,
  blocks: @[Block(label: "entry",term: returns())])])
let rejected=driver.build(foreign,"dev",root/"foreign",Native(name: "foreign"))
doAssert not rejected.success and rejected.error.contains("ABI/attribute needs qualification"),rejected.error
let callback=Type(kind: TypeKind.Function,params: @[overlay],ret: nothing)
var rejectedCallback=""
try:
  discard newSupport().code(Module(externs: @[Extern(name: "foreign_callback",abi: "unknown",params: @[callback],ret: nothing)]))
except ValueError as error: rejectedCallback=error.msg
doAssert rejectedCallback.contains("Unqualified foreign calling convention"),rejectedCallback
let packedRecord=Type(kind: TypeKind.PackedStruct,name: "PackedCodec")
packedRecord.fields["value"]=i9
var rejectedPackedCodec=""
try:
  discard newSupport().code(Module(externs: @[Extern(name: "packed_codec",symbol: "encode",abi: "runtime.codec",
    params: @[packedRecord],ret: Type(kind: TypeKind.Failable,elem: Type(kind: TypeKind.Slice,constant: true,
      elem: Type(kind: TypeKind.Uint,width: 8))))]))
except ValueError as error: rejectedPackedCodec=error.msg
doAssert rejectedPackedCodec.contains("Codec does not support PackedStruct"),rejectedPackedCodec
doAssert report.len == 24
writeFile(root/"report.json",pretty(%*{"complete":true,"passed":true,"observations":report.len,
  "expectedObservations":24,"abiRejections":2,"runtimeRejections":1}))
echo "Typed IR core differential gate passed: ",report.len," observations; block merges and explicit ABI rejection passed"
