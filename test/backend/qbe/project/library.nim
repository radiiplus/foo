import std/[os, osproc, strutils, tables]
import ../../../../src/build/project

when defined(linux):
  let tcc = getEnv("FOO_QBE_CC")
  if tcc.len > 0:
    let root = absolutePath(".artifacts/qbe-project-library")
    createDir(root / "src")
    createDir(root / "native")
    copyFile("test/backend/qbe/fixtures/project/native/src/main.iv",
      root / "src/main.iv")
    copyFile("test/backend/qbe/fixtures/project/native/src/foreign.c",
      root / "native/foreign.c")
    writeFile(root / "project.ivc", """
capability "project"
project {
  name is "qbe-project-library"
  version is "0.1.0"
  entry is "src/main.iv"
  build {
    backend is "qbe"
    link { libs is ["native/libforeign.a"] }
    products { app { kind is "exe" entry is "src/main.iv" } }
  }
}
""")
    let objectFile = root / "native/foreign.o"
    let archive = root / "native/libforeign.a"
    let sysroot = getEnv("FOO_QBE_X64_SYSROOT")
    doAssert sysroot.len > 0
    let compiled = execCmdEx(quoteShell(tcc) & " -B " &
      quoteShell(parentDir(tcc)) & " -I " &
      quoteShell(sysroot / "include") & " -c " &
      quoteShell(root / "native/foreign.c") & " -o " &
      quoteShell(objectFile))
    doAssert compiled.exitCode == 0, compiled.output
    let archived = execCmdEx("ar rcs " & quoteShell(archive) & " " &
      quoteShell(objectFile))
    doAssert archived.exitCode == 0, archived.output
    let built = project(root, Settings(target: "linux-x64", mode: "dev")).build()
    doAssert built.hasKey("app")
    let executed = execCmdEx(quoteShell(built["app"]))
    doAssert executed.exitCode == 0, executed.output
    doAssert "QBE native source: ok" in executed.output

echo "QBE project-relative library: ok"
