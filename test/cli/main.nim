import std/[os, strutils]
import ../../src/cli/main
import ../../src/cli/runner

doAssert main(@[]) == 2
doAssert main(@["version"]) == 0
doAssert main(@["unknown"]) == 2
doAssert main(@["toolchain"]) == 0
doAssert main(@["toolchain", "install", "base"]) == 1
doAssert main(@["build", "--kind", "invalid"]) == 1

let empty = getTempDir() / "foo-empty-test-project"
if dirExists(empty): removeDir(empty)
createDir(empty / "src")
createDir(empty / "test")
writeFile(empty / "project.ivc", """capability "project"
project { name is "empty-test" version is "0.1.0" source is "src" }
""")
writeFile(empty / "src" / "main.iv", "display \"ready\".\n")
doAssert main(@["test", empty, "--backend", "unknown"]) == 1
doAssert main(@["check", empty / "src" / "main.iv", "--compact"]) == 0
let header = empty / "foreign.h"
writeFile(header, "long roundtrip(long value);\n")
doAssert main(@["bind", header]) == 0
doAssert main(@["bind", header, "--target", "windows-x64"]) == 0
let sysroot = empty / "sysroot"
createDir(sysroot / "usr" / "include")
writeFile(sysroot / "usr" / "include" / "target_api.h", "int sysroot_value(int value);\n")
let sysrootHeader = empty / "sysroot.h"
writeFile(sysrootHeader, "#include <target_api.h>\n")
doAssert main(@["bind", sysrootHeader, "--target", "linux-x64", "--sysroot", sysroot]) == 0
removeDir(empty)
block:
  let root = getTempDir() / "foo-cli-runner-test"
  if dirExists(root): removeDir(root)
  createDir(root)
  let file = root / "main.iv"
  writeFile(file, "-- comment\nstart{ give nothing. }\n")
  doAssert check(file, root)
  let formatted = fmt(file)
  doAssert formatted.contains("-- comment")
  doAssert test(root).len == 0
  removeDir(root)
echo "cli main parity: ok"
