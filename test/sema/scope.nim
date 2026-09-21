import ../../src/sema/scope
import ../../src/sema/symbol
import ../../src/sema/form

let parent = newScope()
doAssert parent.insert("answer", Symbol(name: "answer", form: Form.Constant, visible: true))
let child = newScope(parent)
doAssert child.lookup("answer").found
doAssert child.insert("answer", Symbol(name: "duplicate"))
doAssert child.lookupLocal("answer").symbol.name == "duplicate"
echo "semantic scope parity: ok"
