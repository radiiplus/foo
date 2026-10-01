import std/[os, strutils]
import ../src/test/runner

let root = getTempDir() / "foo-test-execute"
if dirExists(root): removeDir(root)
createDir(root)
createDir(root / "src")
createDir(root / "test")
writeFile(root / "src" / "values.iv",
  "public constant answer of type integer is 42.\n")
writeFile(root / "test" / "helper.iv",
  "public function unchanged(value integer) giving integer { give value. }\n")
writeFile(root / "test" / "suite.iv", "use values.\n" &
  "use helper.\n" &
  "extern \"C\" function verify(value integer) giving nothing.\n" &
  "test \"addition\" { verify(helper.unchanged(values.answer)). }\n")
writeFile(root / "working-directory.marker", "project root\n")
writeFile(root / "verify.c", """
#include <stdio.h>
#include <stdlib.h>
void verify(long long value) {
  if (value != 42) exit(32);
  FILE *marker = fopen("working-directory.marker", "rb");
  if (!marker) exit(31);
  fclose(marker);
}
""")
writeFile(root / "project.json", """
{
  "language": "1",
  "name": "runner-working-directory",
  "tests": { "suite": { "sources": ["verify.c"] } }
}
""")
let results = runTests(root, backend = "c")
doAssert results.len == 1
doAssert results[0].suite.name == "addition"
doAssert results[0].passed, results[0].error
removeDir(root)
echo "test execution parity: ok"
