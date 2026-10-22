import ../../src/sema/scope
import ../../src/sema/symbol
import ../../src/sema/form
import std/options
import ../../src/sema/bindings

let parent = scope()
doAssert parent.insert("answer", Symbol(name: "answer", form: Form.Constant, visible: true))
let child = scope(parent)
doAssert child.lookup("answer").found
doAssert child.insert("answer", Symbol(name: "duplicate"))
doAssert child.local("answer").symbol.name == "duplicate"
echo "semantic scope parity: ok"

doAssert binding("text") == some("runtime.text")
doAssert binding("codec") == some("runtime.codec")
doAssert binding("unknown").isNone
doAssert provider("runtime") == "task"
doAssert provider("runtime.io") == "io"
echo "bindings parity: ok"
