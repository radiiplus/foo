import ../../src/types/[coerce, type]
import ../../src/types/env

proc literal(value: string): Type = Type(kind: "literal", value: value)
proc primitive(name: string; width: int): Type =
  Type(kind: "primitive", name: name, width: width)

doAssert coercion(literal("18446744073709551615"),
  primitive("unsigned", 64)).ok
doAssert not coercion(literal("18446744073709551616"),
  primitive("unsigned", 64)).ok
doAssert coercion(literal("340282366920938463463374607431768211455"),
  primitive("unsigned", 128)).ok
doAssert not coercion(literal("340282366920938463463374607431768211456"),
  primitive("unsigned", 128)).ok
doAssert coercion(literal("-170141183460469231731687303715884105728"),
  primitive("integer", 128)).ok
doAssert not coercion(literal("-170141183460469231731687303715884105729"),
  primitive("integer", 128)).ok
doAssert coercion(literal("9007199254740992"),
  primitive("decimal", 64)).ok
doAssert not coercion(literal("9007199254740993"),
  primitive("decimal", 64)).ok
doAssert coercion(primitive("unsigned", 32),
  primitive("integer", 64)).ok
let integer = Type(kind: "optional", elem: primitive("integer", 64))
doAssert not coercion(Type(kind: "primitive", name: "nothing"),
  integer).ok

block codecFunctionAdapter:
  let value = primitive("integer", 64)
  let encoded = Type(kind: "sequence", constant: true,
    elem: primitive("byte", 8))
  let resultType = Type(kind: "error", elem: encoded)
  let runtime = Type(kind: "function", abi: "runtime.codec",
    params: @[value], ret: resultType)
  let plain = Type(kind: "function", params: @[value], ret: resultType)
  doAssert coercion(runtime, plain).ok
  doAssert not coercion(plain, runtime).ok
  doAssert not coercion(Type(kind: "function", abi: "runtime.net",
    params: @[value], ret: resultType), plain).ok
  doAssert not coercion(runtime, Type(kind: "function",
    params: @[primitive("unsigned", 64)], ret: resultType)).ok
  doAssert not coercion(runtime, Type(kind: "function",
    params: @[value], ret: value)).ok

echo "type coercion parity: ok"

block foundation:
  let integer = Type(kind: "primitive", name: "integer", width: 64)
  doAssert label(integer) == "integer"
  doAssert equal(integer, Type(kind: "primitive", name: "integer"))
  let environment = environment()
  environment.define("value", integer, mutable = true, initialized = false)
  doAssert environment.mutable("value") and not environment.initialized("value")
  environment.initialize("value")
  doAssert environment.initialized("value")
  let child = environment.child
  environment.define("later", integer, mutable = true, initialized = false)
  child.initialize("later")
  doAssert environment.initialized("later")
  doAssert coercion(Type(kind: "primitive", name: "integer", width: 32), integer).ok
echo "type foundation parity: ok"
