import std/[os, strutils]
import ../src/test/runner

let root = getTempDir() / "foo-test-execute"
if dirExists(root): removeDir(root)
createDir(root)
writeFile(root / "suite.iv", "use \"c\" function verify() of type nothing.\n" &
  "test \"addition\" { verify(). }\n")
writeFile(root / "working-directory.marker", "project root\n")
writeFile(root / "verify.c", """
#include <stdio.h>
#include <stdlib.h>
void verify(void) {
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
