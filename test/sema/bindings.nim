import std/options
import ../../src/sema/bindings

doAssert binding("text") == some("runtime.text")
doAssert binding("unknown").isNone
doAssert provider("runtime") == "task"
doAssert provider("runtime.io") == "io"
echo "bindings parity: ok"
