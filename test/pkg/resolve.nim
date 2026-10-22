import std/[json, os, tables]
import ../../src/diag/engine
import ../../src/pkg/resolve
import ../../src/pkg/semver as versions
import ../../src/config/project as configuration

let root = getTempDir() / "foo-pkg-resolve-test"
if dirExists(root): removeDir(root)
createDir(root / "deps" / "child")
configuration.writeProject(root / "deps" / "child", %*{
  "name": "child", "version": "1.0.0"})
let manifest = Manifest(name: "app", version: "1.0.0", dependencies: {"child": "path+deps/child"}.toTable)
let diag = engine()
let resolved = resolve(root, manifest, nil, diag)
doAssert resolved.len == 1
doAssert resolved[0].name == "child"
doAssert resolved[0].requiredBy == "root"
doAssert not diag.failed
let conflict = Manifest(name: "app", version: "1.0.0", dependencies: {"child": "path+deps/child", "other": "path+deps/child"}.toTable)
discard resolve(root, conflict, nil, engine())
removeDir(root)
doAssert versions.satisfies("1.9.0", "^1.2.3")
doAssert not versions.satisfies("2.0.0", "^1.2.3")
doAssert versions.satisfies("0.2.9", "^0.2.3")
doAssert not versions.satisfies("0.3.0", "^0.2.3")
doAssert versions.satisfies("1.2.9", "~1.2.3")
doAssert not versions.satisfies("1.3.0", "~1.2.3")
doAssert versions.select(@["1.2.3", "1.9.0", "2.0.0"],
  @["^1.0.0", "~1.9.0"]) == "1.9.0"
doAssert versions.select(@["1.2.3"], @["^2.0.0"]).len == 0
echo "pkg resolve parity: ok"
