import ../../src/types/[coerce, type]

proc literal(value: string): Type = Type(kind: "literal", value: value)
proc primitive(name: string; width: int): Type =
  Type(kind: "primitive", name: name, width: width)

doAssert canCoerce(literal("18446744073709551615"),
  primitive("unsigned", 64)).ok
doAssert not canCoerce(literal("18446744073709551616"),
  primitive("unsigned", 64)).ok
doAssert canCoerce(literal("340282366920938463463374607431768211455"),
  primitive("unsigned", 128)).ok
doAssert not canCoerce(literal("340282366920938463463374607431768211456"),
  primitive("unsigned", 128)).ok
doAssert canCoerce(literal("-170141183460469231731687303715884105728"),
  primitive("integer", 128)).ok
doAssert not canCoerce(literal("-170141183460469231731687303715884105729"),
  primitive("integer", 128)).ok
doAssert canCoerce(literal("9007199254740992"),
  primitive("decimal", 64)).ok
doAssert not canCoerce(literal("9007199254740993"),
  primitive("decimal", 64)).ok
doAssert canCoerce(primitive("unsigned", 32),
  primitive("integer", 64)).ok

echo "type coercion parity: ok"
