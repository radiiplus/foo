import std/[json, os, tables]
import ../../src/diag/engine
import ../../src/pkg/resolve

let root = getTempDir() / "foo-pkg-resolve-test"
if dirExists(root): removeDir(root)
createDir(root / "deps" / "child")
writeFile(root / "deps" / "child" / "project.json", "{\"name\":\"child\",\"version\":\"1.0.0\",\"dependencies\":{}}")
let manifest = Manifest(name: "app", version: "1.0.0", dependencies: {"child": "path+deps/child"}.toTable)
let diag = newEngine()
let resolved = resolveDeps(root, manifest, nil, diag)
doAssert resolved.len == 1
doAssert resolved[0].name == "child"
doAssert resolved[0].requiredBy == "root"
doAssert not diag.failed
let conflict = Manifest(name: "app", version: "1.0.0", dependencies: {"child": "path+deps/child", "other": "path+deps/child"}.toTable)
discard resolveDeps(root, conflict, nil, newEngine())
removeDir(root)
echo "pkg resolve parity: ok"
