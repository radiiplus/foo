import ../../src/types/type
import ../../src/types/env
import ../../src/types/coerce

let integer = Type(kind: "primitive", name: "integer", width: 64)
doAssert typeToString(integer) == "integer 64"
doAssert typesEqual(integer, Type(kind: "primitive", name: "integer"))
let environment = newEnvironment()
environment.define("value", integer, mutable = true, initialized = false)
doAssert environment.mutable("value") and not environment.initialized("value")
environment.initialize("value")
doAssert environment.initialized("value")
let child = environment.child
environment.define("later", integer, mutable = true, initialized = false)
child.initialize("later")
doAssert environment.initialized("later")
doAssert canCoerce(Type(kind: "primitive", name: "integer", width: 32), integer).ok
echo "type foundation parity: ok"
