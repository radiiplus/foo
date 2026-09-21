import std/[json, os]
import ../../src/build/planner

let root = getTempDir() / "foo-build-planner-test"
if dirExists(root): removeDir(root)
createDir(root)
let input = %*{"target": "linux", "values": [1, 2]}
doAssert signature(input) == signature(%*{"values": [1, 2], "target": "linux"})
var calls = 0
let first = newPlanner(root, "compiler")
discard first.run("emit", input, proc(): JsonNode = (inc calls; %*{"code": "example"}))
doAssert calls == 1
let second = newPlanner(root, "compiler")
let reused = second.run("emit", input, proc(): JsonNode = (inc calls; %*{"code": "wrong"}))
doAssert calls == 1
doAssert reused["code"].getStr() == "example"
doAssert second.steps[0].reused
discard second.run("emit", %*{"target": "windows"}, proc(): JsonNode = (inc calls; %*{"code": "windows"}))
doAssert calls == 2
writeFile(root / "emit.plan", "corrupt")
discard newPlanner(root, "compiler").run("emit", input, proc(): JsonNode = (inc calls; %*{"code": "restored"}))
doAssert calls == 3
removeDir(root)
echo "build planner parity: ok"
