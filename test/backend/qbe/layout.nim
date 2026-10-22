import std/tables
import ../../../src/backend/qbe/layout
import ../../../src/ir/[kind, node]

let u3 = `Type`(kind: Shape.Uint, width: 3)
let i65 = `Type`(kind: Shape.Int, width: 65)
doAssert measure(u3).size == 1
doAssert measure(i65).size == 16
doAssert measure(i65).alignment == 16

let packed = `Type`(kind: Shape.PackedStruct,
  fields: toOrderedTable({"low": u3, "flag": `Type`(kind: Shape.Bool),
    "high": `Type`(kind: Shape.Uint, width: 5)}))
doAssert packedBits(packed) == 9
doAssert measure(packed).size == 2
doAssert measure(packed).offsets == @[0, 3, 4]

let tagged = `Type`(kind: Shape.TaggedUnion,
  variants: toOrderedTable({"small": u3, "large": i65}))
doAssert measure(tagged).offsets == @[0, 16]
doAssert measure(tagged).size == 32

let external = `Type`(kind: Shape.ExternUnion,
  fields: toOrderedTable({"small": u3, "large": i65}))
doAssert measure(external).offsets == @[0, 0]
doAssert measure(external).size == 16

let aligned = `Type`(kind: Shape.Uint, width: 32,
  attributes: @["align(16)"])
doAssert measure(aligned).size == 16
doAssert measure(aligned).alignment == 16

echo "QBE layout probe: ok"
