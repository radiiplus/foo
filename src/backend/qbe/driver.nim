import std/[algorithm, json, os, osproc, sets, strutils, tables, times]
import ../../build/[options, execute, cache]
import ../../ir/kind
import ../../ir/node
import ../../ir/reach as reachable
import ../../ir/valid as validation
import ../../opt/arch as targetArch
import ../../opt/gpu as graphics
import ../../pkg/hash as hash
import ./emitter
import ./abi as bridgeAbi
import ./wasm

const runtime = staticRead("../../runtime/qbe.c")
const sharedHashmap = staticRead("../../runtime/provider/hosted.h")
const sharedJson = staticRead("../../runtime/codec/json.h")
const qbeCodec = staticRead("../../runtime/codec/qbe.h")
const memoryRuntime = staticRead("../../runtime/memory/storage.h")
const syscallX64 = staticRead("../../runtime/syscall/x64.s")
const syscallArm64 = staticRead("../../runtime/syscall/arm64.s")
const trace = staticRead("../../runtime/trace.c")
const atomicRv64 = staticRead("../../runtime/atomic/rv64.s")
const atomicX64 = staticRead("../../runtime/atomic/x64.s")
const atomicArm64 = staticRead("../../runtime/atomic/arm64.s")
const volatileX64 = staticRead("../../runtime/volatile/x64.s")
const volatileArm64 = staticRead("../../runtime/volatile/arm64.s")
const volatileRv64 = staticRead("../../runtime/volatile/rv64.s")
const emitterSource = staticRead("emitter.nim")
const abiSource = staticRead("abi.nim")
const layoutSource = staticRead("layout.nim")
const driverSource = staticRead("driver.nim")
const gpuSource = staticRead("../../opt/gpu.nim")
const spirvSource = staticRead("../../opt/spirv.nim")
const wasmSource = staticRead("wasm.nim")
const policy = "qbe-freestanding-memory-v10"

proc directCodec(mode, target, kind: string): bool =
  let selected = getEnv("FOO_QBE_TYPED_CODEC")
  if selected notin ["", "descriptor"]:
    raise newException(ValueError,
      "FOO_QBE_TYPED_CODEC must be empty or descriptor")
  mode == "release" and kind in ["", "exe"] and
    target in ["windows-x64", "linux-x64"] and
    selected != "descriptor"

proc inlineNarrowIntegers(mode, target: string): bool =
  let selected = getEnv("FOO_QBE_NARROW_INLINE")
  if selected notin ["", "0", "1"]:
    raise newException(ValueError,
      "FOO_QBE_NARROW_INLINE must be 0 or 1")
  mode == "release" and target == "windows-x64" and selected != "0"

proc integerRuntimeObject(target: string): string =
  let name = case target
    of "x64-freestanding": "qbe-integer-x64.elfobj"
    of "arm64-freestanding": "qbe-integer-arm64.elfobj"
    of "riscv64-freestanding": "qbe-integer-rv64.elfobj"
    else: return ""
  let installed = getAppDir().parentDir / "vendor" / "tcc" /
    "freestanding" / name
  if fileExists(installed): return absolutePath(installed)
  absolutePath(currentSourcePath().parentDir / ".." / ".." / ".." /
    "vendor" / "tcc" / "freestanding" / name)

type Result* = object
  success*, cached*: bool
  artifact*, output*, error*: string

proc guest(path: string): string =
  let full = absolutePath(path).replace('\\', '/')
  if full.len < 3 or full[1] != ':' or full[2] != '/':
    raise newException(ValueError,
      "QBE WSL tool and build paths must be on a Windows drive: " & full)
  "/mnt/" & $full[0].toLowerAscii() & full[2 .. ^1]

proc tool(environment, fallback: string): string =
  let configured = getEnv(environment)
  cache.executable(if configured.len > 0: configured else: fallback)

proc bundledElfTool(name: string): string =
  for directory in [getAppDir(), parentDir(getAppDir()) / "vendor" /
      "binutils" / "linux-x64", currentSourcePath().parentDir / ".." /
      ".." / ".." / "vendor" / "binutils" / "linux-x64"]:
    let path = directory / name
    if fileExists(path): return absolutePath(path)
  getAppDir() / name

proc linuxTcc(cc, target: string): bool =
  (target == "linux-x64" and cc.lastPathPart == "tcc") or
    (target == "linux-arm64" and cc.lastPathPart == "arm64-tcc")

proc linuxAssets(cc, target: string): tuple[headers, crt, libc, libtcc: string] =
  let arm64 = target == "linux-arm64"
  let root = getEnv(if arm64: "FOO_QBE_ARM64_SYSROOT" else: "FOO_QBE_X64_SYSROOT",
    parentDir(getAppDir()) / "vendor" /
      (if arm64: "arm64-musl" else: "x64-musl"))
  result = (root / "include", root / "lib" / "crt1.o",
    root / "lib" / "libc.a", getEnv(
      if arm64: "FOO_QBE_ARM64_LIBTCC" else: "FOO_QBE_X64_LIBTCC",
      parentDir(cc) / (if arm64: "arm64-libtcc1.a" else: "libtcc1.a")))
  if not dirExists(result.headers):
    raise newException(ValueError, "Linux musl headers missing: " & result.headers)
  for path in [result.crt, result.libc, result.libtcc]:
    if not fileExists(path):
      raise newException(ValueError, "Linux static runtime asset missing: " & path)

proc nativeCompilerFlags(cc, target: string): tuple[clangTarget, linuxFlags: string] =
  if linuxTcc(cc, target):
    let kit = linuxAssets(cc, target)
    result.linuxFlags = " -B " & quoteShell(parentDir(cc)) &
      " -I " & quoteShell(kit.headers)
  if cc.toLowerAscii().lastPathPart.startsWith("clang"):
    result.clangTarget = case target
      of "linux-x64": " -target x86_64-linux-gnu"
      of "linux-arm64": " -target aarch64-linux-gnu"
      of "x64-freestanding": " -target x86_64-none-elf"
      of "arm64-freestanding": " -target aarch64-none-elf"
      of "riscv64-freestanding": " -target riscv64-none-elf"
      else: ""

proc linuxAssembler(cc, target: string): string =
  if target notin ["linux-x64", "linux-arm64", "x64-freestanding",
      "arm64-freestanding", "riscv64-freestanding"]:
    return cc
  let name = case target
    of "linux-arm64", "arm64-freestanding": "qbe-as-arm64"
    of "riscv64-freestanding": "qbe-as-riscv64"
    else: "qbe-as"
  let local = getAppDir() / name
  let configured = getEnv("FOO_QBE_AS")
  if configured.len > 0: return tool("FOO_QBE_AS", configured)
  if fileExists(local): return tool("FOO_QBE_AS", local)
  if target == "linux-x64" and linuxTcc(cc, target):
    return tool("FOO_QBE_AS", "as")
  cc

proc assembleNative(cc, target, assembly, output: string): tuple[output: string,
    exitCode: int] =
  let assembler = linuxAssembler(cc, target)
  if assembler == cc and not assembler.lastPathPart.startsWith("qbe-as"):
    return execute.captureArgs(cc, @["-c", assembly, "-o", output])
  if assembler.lastPathPart.startsWith("qbe-as"):
    when defined(windows):
      return execute.captureArgs("wsl.exe", @["--exec", "env",
        "LD_LIBRARY_PATH=" & guest(parentDir(assembler)), guest(assembler),
        guest(assembly), "-o", guest(output)])
    else:
      return execute.captureArgs("env", @["LD_LIBRARY_PATH=" &
        parentDir(assembler), assembler, assembly, "-o", output])
  execute.captureArgs(assembler, @[assembly, "-o", output])

proc linkerCommand(linker: string): string =
  when defined(windows):
    if linker.lastPathPart.startsWith("qbe-ld"):
      return "wsl.exe --exec env LD_LIBRARY_PATH=" &
        quoteShell(guest(parentDir(linker))) & " " & quoteShell(guest(linker))
  (if linker.lastPathPart.startsWith("qbe-ld"):
    "env LD_LIBRARY_PATH=" & quoteShell(parentDir(linker)) & " "
  else: "") & quoteShell(linker)

proc linkerPath(path, linker: string): string =
  when defined(windows):
    if linker.lastPathPart.startsWith("qbe-ld"): return guest(path)
  path

proc nativeInputs(options: options.Native; cc = ""): string =
  var entries: seq[string]
  for path in options.sources & options.objects & options.libs:
    if fileExists(path):
      entries.add(absolutePath(path) & "\0" & hash.checksum(path))
    elif path in options.sources or path in options.objects or
        path.contains('/') or path.contains('\\'):
      raise newException(ValueError, "QBE native input missing: " & path)
  for directory in options.includes:
    if not dirExists(directory):
      raise newException(ValueError, "QBE include directory missing: " & directory)
    for path in walkDirRec(directory):
      if fileExists(path):
        entries.add(absolutePath(path) & "\0" & hash.checksum(path))
  if cc.len > 0 and options.sources.len > 0:
    let flags = nativeCompilerFlags(cc, options.target)
    for source in options.sources:
      var command = quoteShell(cc) & flags.clangTarget & flags.linuxFlags &
        " -std=c11 -E " & quoteShell(source)
      for included in options.includes:
        command.add(" -I " & quoteShell(included))
      for flag in options.flags:
        command.add(" " & quoteShell(flag))
      let preprocessed = execute.capture(command)
      if preprocessed.exitCode != 0:
        raise newException(IOError,
          "QBE external source preprocessing failed: " & preprocessed.output)
      entries.add(absolutePath(source) & "\0preprocessed\0" &
        hash.digest(preprocessed.output))
  entries.sort()
  hash.digest(entries.join("\n"))

proc nativeLibraries(options: options.Native; linker: string): string =
  for library in options.libs:
    if library.len == 0:
      raise newException(ValueError, "QBE library name cannot be empty")
    if fileExists(library):
      result.add(" " & quoteShell(linkerPath(absolutePath(library), linker)))
    else:
      for character in library:
        if not (character.isAlphaNumeric or character in {'_', '-', '.', '+'}):
          raise newException(ValueError, "Invalid QBE library name: " & library)
      result.add(" " & quoteShell("-l" & library))

proc winapiDef(cc: string): string =
  let packaged = parentDir(cc) / "lib" / "foo-winapi.def"
  if fileExists(packaged): return packaged
  let source = currentSourcePath().parentDir / ".." / ".." / ".." /
    "tools" / "tcc" / "foo-winapi.def"
  if fileExists(source): return absolutePath(source)
  raise newException(ValueError, "TinyCC Windows import definitions are missing")

proc peExports(path: string): HashSet[string] =
  let data = readFile(path)
  proc word(offset: int): int =
    if offset < 0 or offset > data.len - 2:
      raise newException(ValueError, "Invalid PE export table")
    ord(data[offset]) or (ord(data[offset + 1]) shl 8)
  proc dword(offset: int): int =
    if offset < 0 or offset > data.len - 4:
      raise newException(ValueError, "Invalid PE export table")
    ord(data[offset]) or (ord(data[offset + 1]) shl 8) or
      (ord(data[offset + 2]) shl 16) or (ord(data[offset + 3]) shl 24)
  if data.len < 64 or data[0 .. 1] != "MZ":
    raise newException(ValueError, "Shared output is not PE")
  let pe = dword(60)
  if pe > data.len - 24 or data[pe .. pe + 3] != "PE\0\0":
    raise newException(ValueError, "Shared output has invalid PE header")
  let coff = pe + 4
  let sections = word(coff + 2)
  let optionalSize = word(coff + 16)
  let optional = coff + 20
  if sections > 96 or optionalSize < 120 or
      optional > data.len - optionalSize or word(optional) != 0x20b:
    raise newException(ValueError, "Shared output has invalid PE32+ header")
  let exportRva = dword(optional + 112)
  let table = optional + optionalSize
  proc fileOffset(rva: int): int =
    for index in 0..<sections:
      let section = table + index * 40
      let address = dword(section + 12)
      let size = dword(section + 16)
      if rva >= address and rva - address < size:
        let offset = dword(section + 20) + rva - address
        if offset >= data.len:
          raise newException(ValueError, "Invalid PE export address")
        return offset
    raise newException(ValueError, "PE export address is not mapped")
  result = initHashSet[string]()
  if exportRva == 0: return
  let header = fileOffset(exportRva)
  let functions = dword(header + 20)
  let names = dword(header + 24)
  if names > 10000 or functions != names:
    raise newException(ValueError, "Shared output has unnamed or excessive exports")
  let namesOffset = fileOffset(dword(header + 32))
  for index in 0..<names:
    let address = fileOffset(dword(namesOffset + index * 4))
    var finish = address
    while finish < data.len and data[finish] != '\0' and finish - address < 4096:
      inc finish
    if finish == data.len or finish - address == 4096:
      raise newException(ValueError, "Invalid PE export name")
    result.incl(data[address ..< finish])

proc interruptAssembly(name: string; index: int): string =
  let symbol = "foo." & name
  let saved = ".Lqbe_irq_saved_" & $index
  let restored = ".Lqbe_irq_restored_" & $index
  result.add("\n.text\n.balign 4\n.globl " & symbol & "\n" & symbol &
    ":\n\taddi sp, sp, -512\n")
  var offset = 0
  for register in 1..31:
    if register == 2: continue
    result.add("\tsd x" & $register & ", " & $offset & "(sp)\n")
    offset += 8
  result.add("\tcsrr t0, mstatus\n\tsd t0, 240(sp)\n" &
    "\tli t1, 0x6000\n\tand t0, t0, t1\n\tbeqz t0, " &
    saved & "\n\tfrcsr t0\n\tsd t0, 248(sp)\n")
  for register in 0..31:
    result.add("\tfsd f" & $register & ", " & $(256 + register * 8) &
      "(sp)\n")
  result.add(saved & ":\n\tcall foo.qbe.interrupt." & name & "\n" &
    "\tld t0, 240(sp)\n\tli t1, 0x6000\n\tand t0, t0, t1\n" &
    "\tbeqz t0, " & restored & "\n")
  for register in 0..31:
    result.add("\tfld f" & $register & ", " & $(256 + register * 8) &
      "(sp)\n")
  result.add("\tld t0, 248(sp)\n\tfscsr t0\n" & restored &
    ":\n\tld t0, 240(sp)\n\tcsrw mstatus, t0\n")
  offset = 0
  for register in 1..31:
    if register == 2: continue
    result.add("\tld x" & $register & ", " & $offset & "(sp)\n")
    offset += 8
  result.add("\taddi sp, sp, 512\n\tmret\n")

proc arm64InterruptAssembly(name: string; level = 1): string =
  let trapRegister = if level == 1: "cpacr_el1" else: "cptr_el" & $level
  let returnRegister = "elr_el" & $level
  let statusRegister = "spsr_el" & $level
  result.add("\n.text\n.balign 4\n.globl foo." & name &
    "\nfoo." & name & ":\n\tsub sp, sp, #816\n")
  for pair in 0..14:
    result.add("\tstp x" & $(pair * 2) & ", x" & $(pair * 2 + 1) &
      ", [sp, #" & $(pair * 16) & "]\n")
  result.add("\tstr x30, [sp, #240]\n" &
    "\tmrs x0, " & trapRegister & "\n\tstr x0, [sp, #800]\n" &
    (if level == 1: "\torr x0, x0, #0x300000\n" else:
      "\tbic x0, x0, #0x400\n") &
    "\tmsr " & trapRegister & ", x0\n\tisb\n")
  for pair in 0..15:
    result.add("\tstp q" & $(pair * 2) & ", q" & $(pair * 2 + 1) &
      ", [sp, #" & $(256 + pair * 32) & "]\n")
  for (register, offset) in [("fpcr", 768), ("fpsr", 776),
      (returnRegister, 784), (statusRegister, 792)]:
    result.add("\tmrs x0, " & register & "\n\tstr x0, [sp, #" &
      $offset & "]\n")
  result.add("\tbl foo.qbe.interrupt." & name & "\n")
  for (register, offset) in [(statusRegister, 792), (returnRegister, 784),
      ("fpsr", 776), ("fpcr", 768)]:
    result.add("\tldr x0, [sp, #" & $offset & "]\n\tmsr " &
      register & ", x0\n")
  for pair in 0..15:
    result.add("\tldp q" & $(pair * 2) & ", q" & $(pair * 2 + 1) &
      ", [sp, #" & $(256 + pair * 32) & "]\n")
  result.add("\tldr x0, [sp, #800]\n\tmsr " & trapRegister & ", x0\n" &
    "\tisb\n\tldr x30, [sp, #240]\n")
  for pair in 0..14:
    result.add("\tldp x" & $(pair * 2) & ", x" & $(pair * 2 + 1) &
      ", [sp, #" & $(pair * 16) & "]\n")
  result.add("\tadd sp, sp, #816\n\teret\n")

proc x64InterruptAssembly(name: string; errorCode = false): string =
  result.add("\n.text\n.balign 16\n.globl foo." & name &
    "\nfoo." & name & ":\n")
  let registers = ["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"]
  for register in registers:
    result.add("\tpushq %" & register & "\n")
  result.add("\tmovq %rsp, %rax\n\tsubq $528, %rsp\n" &
    "\tandq $-16, %rsp\n\tmovq %rax, 512(%rsp)\n" &
    "\tfxsave64 (%rsp)\n" &
    (if errorCode:
      "\tmovq 512(%rsp), %rdi\n\tmovq 120(%rdi), %rdi\n"
     else: "") &
    "\tcall foo.qbe.interrupt." & name &
    "\n\tfxrstor64 (%rsp)\n\tmovq 512(%rsp), %rsp\n")
  for index in countdown(registers.high, 0):
    result.add("\tpopq %" & registers[index] & "\n")
  if errorCode: result.add("\taddq $8, %rsp\n")
  result.add("\tiretq\n")

proc rv64PcRelative(assembly: string): string =
  let lines = assembly.splitLines()
  var position = 0
  var label = 0
  while position < lines.len:
    let line = lines[position]
    let marker = line.find(", %hi(")
    if line.startsWith("\tlui ") and marker > 5 and
        line.endsWith(")") and position + 1 < lines.len:
      let register = line[5 ..< marker]
      let symbol = line[marker + 6 ..< line.len - 1]
      let next = "\taddi " & register & ", " & register &
        ", %lo(" & symbol & ")"
      if lines[position + 1] == next:
        let anchor = ".Lqbe_pcrel_" & $label
        inc label
        result.add(anchor & ":\n\tauipc " & register &
          ", %pcrel_hi(" & symbol & ")\n\taddi " & register &
          ", " & register & ", %pcrel_lo(" & anchor & ")\n")
        position += 2
        continue
    result.add(line & "\n")
    inc position

proc shaderValidator(): string =
  let bundled = currentSourcePath().parentDir / ".." / ".." / ".." /
    "vendor" / "spirv-tools" /
    (when defined(windows): "windows-x64" else: "linux-x64") /
    (when defined(windows): "spirv-val.exe" else: "spirv-val")
  let adjacent = getAppDir() / (when defined(windows): "spirv-val.exe" else: "spirv-val")
  let fallback = if fileExists(adjacent): adjacent
    elif fileExists(bundled): bundled else: "spirv-val"
  tool("FOO_SPIRV_VAL", fallback)

proc shaderIdentity(mode: string; options: options.Native): string =
  options.validate()
  if options.kind != "shader" or options.runtime.len > 0 or options.threads or
      options.sources.len > 0 or options.objects.len > 0 or options.libs.len > 0 or
      options.includes.len > 0 or options.flags.len > 0 or
      options.frameworks.len > 0 or options.cpp or options.debug or
      options.docs or options.coverage.len > 0 or options.profile.len > 0 or
      options.sanitize.len > 0 or options.icon.len > 0 or
      options.script.len > 0 or options.exports.len > 0 or
      options.rpath.len > 0 or options.cpu.len > 0 or
      options.native.substrate.len > 0:
    raise newException(ValueError, "Shader product has unsupported native build options")
  let validator = shaderValidator()
  $(%*{"backend": "qbe", "policy": "spirv-vulkan1.3-v1",
    "target": options.target, "mode": mode, "format": "SPIR-V",
    "validator": validator, "validatorSha256": hash.checksum(validator),
    "gpuSha256": hash.digest(gpuSource),
    "spirvSha256": hash.digest(spirvSource),
    "driverSha256": hash.digest(driverSource)})

proc wasmTarget(options: options.Native): bool =
  options.target in ["wasi", "wasi-threads", "wasm-freestanding"]

proc wasmIdentity(mode: string; options: options.Native): string =
  options.validate()
  if mode notin ["dev", "release"]:
    raise newException(ValueError, "Unknown WebAssembly build mode '" & mode & "'")
  if options.threads and options.target != "wasi-threads":
    raise newException(ValueError,
      "WASI threads require the wasi-threads target")
  if options.kind notin ["", "exe", "object"] or
      options.runtime notin ["", "none"] or options.sources.len > 0 or
      options.objects.len > 0 or options.libs.len > 0 or
      options.includes.len > 0 or options.flags.len > 0 or
      options.frameworks.len > 0 or options.cpp or options.debug or
      options.docs or options.coverage.len > 0 or options.profile.len > 0 or
      options.sanitize.len > 0 or options.icon.len > 0 or
      options.script.len > 0 or options.exports.len > 0 or
      options.rpath.len > 0 or options.cpu.len > 0 or
      options.native.substrate.len > 0:
    raise newException(ValueError, "WebAssembly build has unsupported native options")
  let localWabt = getAppDir() / (when defined(windows): "wat2wasm.exe" else: "wat2wasm")
  let assembler = tool("FOO_WAT2WASM",
    if fileExists(localWabt): localWabt else: "wat2wasm")
  $(%*{"backend": "qbe", "policy": "wabt-direct-module-v6",
    "target": options.target, "mode": mode,
    "wat2wasm": %*{"path": assembler,
      "sha256": hash.checksum(assembler)},
    "linkPolicy": (if options.kind == "object": "relocatable-wabt-v1"
      else: "direct-wabt-v1"),
    "wasmEmitterSha256": hash.digest(wasmSource),
    "driverSha256": hash.digest(driverSource)})

proc selected(options: options.Native; mode: string): tuple[qbe, cc, linker, target: string] =
  options.validate()
  if mode notin ["dev", "release"]:
    raise newException(ValueError, "Unknown QBE build mode '" & mode & "'")
  let uefi = options.target == "uefi-x64"
  let freestanding = options.target.endsWith("-freestanding") or uefi
  when not defined(windows):
    if uefi:
      raise newException(ValueError,
        "UEFI x64 currently requires the qualified Windows TinyCC PE toolchain")
  let qbeTarget = case options.target
    of "windows-x64", "uefi-x64": "amd64_win"
    of "linux-x64", "x64-freestanding": "amd64_sysv"
    of "linux-arm64", "arm64-freestanding": "arm64"
    of "riscv64-freestanding": "rv64"
    of "wasi", "wasi-threads", "wasm-freestanding":
      raise newException(ValueError,
        "QBE cannot target WebAssembly; " & options.target &
        " requires a separate WASM backend")
    else: raise newException(ValueError, "QBE target is not supported: " & options.target)
  if options.kind notin ["", "exe", "object", "static", "shared"] or
      (freestanding and options.kind notin ["", "exe", "object", "static"]) or
      (uefi and options.kind notin ["", "exe"]) or
      options.runtime notin (if freestanding: @["", "none"] else: @["", "hosted"]):
    raise newException(ValueError,
      "QBE supports hosted executables/objects and freestanding ELF, objects or archives")
  let localArmTcc = getAppDir() / "arm64-tcc"
  if not freestanding and options.target != (when defined(windows): "windows-x64"
      elif defined(arm64): "linux-arm64" else: "linux-x64") and
      getEnv("FOO_QBE_CC").len == 0 and options.compiler.len == 0 and
      not (options.target == "linux-arm64" and fileExists(localArmTcc)):
    raise newException(ValueError,
      "Cross-target QBE build requires FOO_QBE_CC for " & options.target)
  if options.frameworks.len > 0 or
      options.cpp or options.debug or options.docs or
      options.coverage.len > 0 or options.profile.len > 0 or options.sanitize.len > 0 or
      options.icon.len > 0 or (options.script.len > 0 and
        (not freestanding or uefi)) or options.exports.len > 0 or
      options.rpath.len > 0 or options.native.substrate.len > 0:
    raise newException(ValueError, "QBE driver does not support this native build configuration")
  if options.kind == "shared" and (options.target != "windows-x64" or
      options.soname.len > 0 or options.version.len > 0):
    raise newException(ValueError,
      "QBE shared libraries currently require windows-x64 without ELF soname/version")
  if freestanding and not uefi and options.sources.len > 0:
    raise newException(ValueError,
      "Freestanding C sources require a target C compiler; supply prebuilt objects")
  if uefi and options.libs.len > 0:
    raise newException(ValueError,
      "UEFI applications cannot link hosted libraries")
  if options.kind == "object" and
      (options.sources.len > 0 or options.objects.len > 0 or options.libs.len > 0):
    raise newException(ValueError,
      "QBE object products cannot combine external native inputs")
  if options.kind == "static" and options.libs.len > 0:
    raise newException(ValueError,
      "QBE static archives cannot link external libraries")
  discard nativeInputs(options)
  discard targetArch.profile(options.target, options.cpu)
  let localQbe = getAppDir() / (when defined(windows): "qbe.exe" else: "qbe")
  let qbe = tool("FOO_QBE", if fileExists(localQbe): localQbe else: "qbe")
  let localTcc = getAppDir() / (when defined(windows): "tcc.exe" else: "tcc")
  let localAssembler = bundledElfTool(case options.target
    of "arm64-freestanding": "qbe-as-arm64"
    of "riscv64-freestanding": "qbe-as-riscv64"
    else: "qbe-as")
  let localLinker = bundledElfTool(case options.target
    of "arm64-freestanding": "qbe-ld-arm64"
    of "riscv64-freestanding": "qbe-ld-riscv64"
    else: "qbe-ld")
  let compiler = if options.compiler.len > 0: options.compiler
    elif freestanding:
      (if uefi: (if fileExists(localTcc): localTcc else: "tcc.exe")
        elif getEnv("FOO_QBE_AS").len > 0: getEnv("FOO_QBE_AS")
        else: localAssembler)
    elif options.target == "linux-arm64":
      (if fileExists(localArmTcc): localArmTcc else: "aarch64-linux-gnu-gcc")
    elif options.target == "linux-x64" and fileExists(localTcc): localTcc
    elif options.target == "windows-x64":
      (if fileExists(localTcc): localTcc else: "tcc.exe")
    else: "cc"
  let cc = tool(if options.target in ["windows-x64", "uefi-x64"]:
      "FOO_QBE_TCC" else: "FOO_QBE_CC", compiler)
  if uefi and not cc.toLowerAscii().lastPathPart.startsWith("tcc"):
    raise newException(ValueError, "UEFI PE32+ requires vendored TinyCC")
  if linuxTcc(cc, options.target): discard linuxAssets(cc, options.target)
  let linker = if options.kind in ["", "exe", "shared"]:
      tool("FOO_QBE_LINKER", if options.target in ["windows-x64", "uefi-x64"]: cc
        elif freestanding: localLinker
        else: cc)
    else: ""
  if options.script.len > 0 and not fileExists(options.script):
    raise newException(ValueError, "Linker script not found: " & options.script)
  (qbe, cc, linker, qbeTarget)

proc identity*(mode: string; options: options.Native): string =
  if options.kind == "shader": return shaderIdentity(mode, options)
  if wasmTarget(options): return wasmIdentity(mode, options)
  let tools = selected(options, mode)
  let qbeHash = hash.checksum(tools.qbe)
  let ccHash = hash.checksum(tools.cc)
  let assembler = linuxAssembler(tools.cc, options.target)
  let assemblerHash = hash.checksum(assembler)
  var supportHash = ""
  if options.target in ["windows-x64", "uefi-x64"]:
    let home = parentDir(tools.cc)
    var support: seq[string] = @[home / "libtcc.dll"]
    for directory in [home / "include", home / "lib"]:
      if not dirExists(directory):
        raise newException(ValueError, "TinyCC support directory missing: " & directory)
      for path in walkDirRec(directory): support.add(path)
    support.sort()
    var contents = ""
    for path in support:
      if not fileExists(path):
        raise newException(ValueError, "TinyCC support asset missing: " & path)
      contents.add(relativePath(path, home) & "\0" & hash.checksum(path) & "\n")
    supportHash = hash.digest(contents)
  elif linuxTcc(tools.cc, options.target):
    let kit = linuxAssets(tools.cc, options.target)
    var support: seq[string] = @[kit.crt, kit.libc, kit.libtcc]
    support.add(parentDir(tools.cc) / "include" / "stdatomic.h")
    for path in walkDirRec(kit.headers): support.add(path)
    support.sort()
    var contents = ""
    for path in support:
      if not fileExists(path):
        raise newException(ValueError, "Linux support asset missing: " & path)
      contents.add(path & "\0" & hash.checksum(path) & "\n")
    supportHash = hash.digest(contents)
  let nativeArm64Assembler = (when defined(linux) and defined(arm64):
    options.target == "linux-arm64" and
      assembler == absolutePath(getAppDir() / "qbe-as-arm64")
  else: false)
  if assembler.lastPathPart.startsWith("qbe-as") and not nativeArm64Assembler:
    let suffix = case assembler.lastPathPart
      of "qbe-as-arm64": "arm64"
      of "qbe-as-riscv64": "riscv64"
      else: "system"
    for name in ["libbfd-2.38-" & suffix & ".so",
        "libopcodes-2.38-" & suffix & ".so", "libz.so.1"]:
      let path = parentDir(assembler) / name
      if not fileExists(path):
        raise newException(ValueError, "Bundled assembler library missing: " & path)
      supportHash = hash.digest(supportHash & "\n" & name & "\0" &
        hash.checksum(path))
  if tools.linker.lastPathPart.startsWith("qbe-ld"):
    let libraries = case tools.linker.lastPathPart
      of "qbe-ld-arm64": @["libbfd-2.38-arm64.so", "libctf-arm64.so.0", "libz.so.1"]
      of "qbe-ld-riscv64": @["libbfd-2.38-riscv64.so",
        "libctf-riscv64.so.0", "libz.so.1"]
      else: @["libbfd-2.38-system.so", "libctf.so.0", "libz.so.1"]
    for name in libraries:
      let path = parentDir(tools.linker) / name
      if not fileExists(path):
        raise newException(ValueError, "Bundled linker library missing: " & path)
      supportHash = hash.digest(supportHash & "\n" & name & "\0" &
        hash.checksum(path))
  let linkerHash = if tools.linker.len > 0: hash.checksum(tools.linker) else: ""
  let emitterHash = hash.digest(emitterSource)
  let layoutHash = hash.digest(layoutSource)
  let driverHash = hash.digest(driverSource)
  let runtimeHash = hash.digest(runtime & sharedHashmap & sharedJson & qbeCodec &
    memoryRuntime &
    trace & atomicRv64 & atomicX64 & atomicArm64 & volatileX64 &
    volatileArm64 & volatileRv64)
  let syscallHash = if options.target == "linux-x64": hash.digest(syscallX64)
    elif options.target == "linux-arm64": hash.digest(syscallArm64) else: ""
  let archiver = if options.kind == "static":
      cache.executable(getEnv("FOO_QBE_AR", "ar")) else: ""
  let archiverHash = if archiver.len > 0: hash.checksum(archiver) else: ""
  $(%*{"backend": "qbe", "policy": policy, "target": options.target,
    "mode": mode, "cpu": targetArch.profile(options.target, options.cpu).cpu,
    "runtimeOptimization": (if options.target.endsWith("-freestanding") or
        options.target == "uefi-x64":
      "none" else: "O0"),
    "runtimeCopyPolicy": (if options.target == "linux-x64" and
        linuxTcc(tools.cc, options.target):
      "tcc-inline-small-copy-when-available-v1" else: "libc-memcpy-v1"),
    "checkedInlinePolicy": (if mode == "release" and options.target in
        ["linux-x64", "windows-x64"]:
      "private-guarded-constructor-v1" else: "disabled"),
    "narrowIntegerPolicy": (if inlineNarrowIntegers(mode, options.target):
      "inline-checked-w1-63-v1" else: "generic-checked-w1-63-v1"),
    "codecLoweringPolicy": (if directCodec(mode, options.target, options.kind):
      "direct-u64-bool-record-v1" else: "descriptor-v1"),
    "qbe": %*{"path": tools.qbe, "sha256": qbeHash},
    "cc": %*{"path": tools.cc, "sha256": ccHash},
    "assembler": %*{"path": assembler, "sha256": assemblerHash},
    "compilerSupportSha256": supportHash,
    "nativeInputsSha256": nativeInputs(options, tools.cc),
    "nativeSources": options.sources, "nativeObjects": options.objects,
    "nativeLibraries": options.libs, "nativeIncludes": options.includes,
    "nativeFlags": options.flags,
    "winapiSha256": (if options.target == "windows-x64" and options.kind in ["", "exe", "shared"]:
      hash.checksum(winapiDef(tools.cc)) else: ""),
    "linker": %*{"path": tools.linker, "sha256": linkerHash},
    "scriptSha256": (if options.script.len > 0: hash.checksum(options.script) else: ""),
    "emitterSha256": emitterHash, "abiSha256": hash.digest(abiSource),
    "layoutSha256": layoutHash,
    "driverSha256": driverHash,
    "linkPolicy": (if options.target.endsWith("-freestanding") or
        options.target == "uefi-x64":
      (if options.target == "uefi-x64": "tcc-pe32plus-efiapp-reloc-v2"
       elif tools.linker.lastPathPart.startsWith("qbe-ld"):
        "bundled-bfd-no-undefined-gc-sections-entry-page4k-v1"
       else: "lld-no-undefined-gc-sections-entry-page4k-v2")
      else: "hosted-v1"),
    "runtimeSha256": runtimeHash, "syscallAssemblySha256": syscallHash,
    "archiver": archiver, "archiverSha256": archiverHash,
    "qbeTarget": tools.target})

proc build*(module: Module; mode, directory: string;
    options = options.Native(); sourceFile = "main.iv";
    progress: Observer = nil; toolIdentity = ""): Result =
  try:
    if options.kind == "shader":
      let descriptor = if toolIdentity.len > 0: toolIdentity
        else: shaderIdentity(mode, options)
      let errors = validation.validate(module)
      if errors.len > 0:
        raise newException(ValueError,
          "Invalid typed IR before SPIR-V lowering: " & errors[0].msg)
      var kernel: node.Function
      for fn in module.funcs:
        if fn.abi != "gpu": continue
        if kernel != nil:
          raise newException(ValueError,
            "Shader product requires exactly one GPU function")
        kernel = fn
      if kernel == nil:
        raise newException(ValueError,
          "Shader product requires exactly one GPU function")
      let binary = graphics.compile(kernel)
      createDir(directory)
      let destination = absolutePath(directory / artifact(options))
      let metadata = destination & ".json"
      let selectedCache = cache.cache(destination,
        hash.digest(descriptor & "\n" & hash.digest(binary) & "\n" & $options))
      result.artifact = destination
      if selectedCache.valid():
        result.success = true
        result.cached = true
        return
      writeFile(destination, binary)
      let validator = shaderValidator()
      let checked = execute.captureArgs(validator,
        @["--target-env", "vulkan1.3", destination])
      if checked.exitCode != 0:
        removeFile(destination)
        raise newException(IOError, "SPIR-V validation failed: " & checked.output)
      let data = parseJson(descriptor)
      data["entry"] = %kernel.name
      data["targetEnvironment"] = %"vulkan1.3"
      data["sha256"] = %hash.digest(binary)
      writeFile(metadata, pretty(data) & "\n")
      selectedCache.save(@[destination, metadata])
      result.success = true
      if progress != nil: progress("compiled", options.name, destination, false)
      return
    if wasmTarget(options):
      let profiling = getEnv("FOO_BUILD_PROFILE") == "1"
      var clock = epochTime()
      proc mark(stage: string) =
        if profiling:
          let now = epochTime()
          stderr.writeLine("build-profile wasm " & stage & " " &
            $(int((now - clock) * 1000 + 0.5)) & " ms")
          clock = now
      let descriptor = if toolIdentity.len > 0: toolIdentity
        else: wasmIdentity(mode, options)
      let errors = validation.validate(module)
      if errors.len > 0:
        raise newException(ValueError,
          "Invalid typed IR before WebAssembly lowering: " & errors[0].msg)
      let wat = wasm.emit(module, entry = options.kind in ["", "exe"] and
        options.target in ["wasi", "wasi-threads"],
        shared = options.target == "wasi-threads")
      mark("emit")
      createDir(directory)
      let destination = absolutePath(directory / artifact(options))
      let metadata = destination & ".qbe.json"
      let selectedCache = cache.cache(destination,
        hash.digest(descriptor & "\n" & hash.digest(wat) & "\n" & $options))
      result.artifact = destination
      if selectedCache.valid():
        result.success = true
        result.cached = true
        return
      let source = absolutePath(directory / "main.wat")
      let objectFile = destination
      writeFile(source, wat)
      let tools = parseJson(descriptor)
      var watArgs: seq[string]
      if options.kind == "object": watArgs.add("--relocatable")
      if options.target == "wasi-threads": watArgs.add("--enable-threads")
      watArgs.add(@[source, "-o", objectFile])
      let assembled = execute.captureArgs(tools["wat2wasm"]["path"].getStr(),
        watArgs)
      if assembled.exitCode != 0:
        raise newException(IOError, "WABT assembly failed: " & assembled.output)
      mark("wabt")
      result.output = assembled.output
      writeFile(metadata, pretty(tools) & "\n")
      selectedCache.save(@[destination, metadata, source])
      result.success = true
      if progress != nil: progress("compiled", options.name, destination, false)
      return
    let profiling = getEnv("FOO_BUILD_PROFILE") == "1"
    var clock = epochTime()
    proc mark(stage: string) =
      if profiling:
        let now = epochTime()
        stderr.writeLine("build-profile qbe " & stage & " " &
          $(int((now - clock) * 1000 + 0.5)) & " ms")
        clock = now
    let tools = selected(options, mode)
    let prepared = reachable.reach(module,
      library = options.kind in ["object", "static", "shared"] or
        options.target.endsWith("-freestanding") or
        options.target == "uefi-x64")
    let errors = validation.validate(prepared)
    if errors.len > 0:
      raise newException(ValueError, "Invalid typed IR before QBE lowering: " & errors[0].msg)
    createDir(directory)
    let uefi = options.target == "uefi-x64"
    let freestanding = options.target.endsWith("-freestanding") or uefi
    if uefi and options.kind in ["", "exe"]:
      var validEntry = false
      for fn in prepared.funcs:
        if fn.name == "efi_main" and fn.public and fn.abi == "c" and
            fn.params.len == 2 and fn.ret != nil and
            fn.ret.kind == Shape.Uint and fn.ret.width == 64 and
            fn.params[0].type != nil and fn.params[0].type.kind == Shape.Ptr and
            fn.params[1].type != nil and fn.params[1].type.kind == Shape.Ptr:
          validEntry = true
      if not validEntry:
        raise newException(ValueError,
          "UEFI application needs public C efi_main(handle: pointer, system_table: pointer): u64")
    let il = emitter.emit(prepared, sourceFile,
      entry = options.kind in ["", "exe"] and not freestanding,
      target = (if uefi: "windows-x64" else: options.target), cpu = options.cpu,
      typedCodec = directCodec(mode, options.target, options.kind),
      inlineNarrowIntegers = inlineNarrowIntegers(mode, options.target))
    mark("reach-emit")
    var nativeAssembly = ""
    var functionAssembly = ""
    var contracts = initTable[string, Contract]()
    var usedContracts = initHashSet[string]()
    for contract in module.native:
      if contract.id in contracts:
        raise newException(ValueError, "Duplicate native contract: " & contract.id)
      contracts[contract.id] = contract
    var startup = ""
    var attributeIdentity = ""
    for index, fn in prepared.funcs:
      attributeIdentity.add(fn.name & "\0" & fn.attributes.join("\0") & "\n")
      if "start" in fn.attributes:
        if startup.len > 0:
          raise newException(ValueError, "Multiple startup functions")
        startup = if fn.abi == "c": fn.name else: "foo." & fn.name
      var interrupt = ""
      for attribute in fn.attributes:
        if attribute in ["interrupt", "interrupt_error_code",
            "interrupt_el2", "interrupt_el3"]:
          interrupt = attribute
      if interrupt.len > 0:
        functionAssembly.add(case options.target
          of "arm64-freestanding": arm64InterruptAssembly(fn.name,
            if interrupt == "interrupt_el2": 2
            elif interrupt == "interrupt_el3": 3 else: 1)
          of "x64-freestanding": x64InterruptAssembly(fn.name,
            interrupt == "interrupt_error_code")
          else: interruptAssembly(fn.name, index))
      if "naked" notin fn.attributes: continue
      let symbol = if fn.abi == "c": fn.name else: "foo." & fn.name
      functionAssembly.add("\n.text\n.globl " & symbol & "\n" & symbol & ":\n")
      for instruction in fn.blocks[0].instrs:
        if instruction.symbol notin contracts:
          raise newException(ValueError, "Missing assembly contract: " &
            instruction.symbol)
        let contract = contracts[instruction.symbol]
        if contract.stage != "@asm" or contract.abi notin ["foo:1", "c"]:
          raise newException(ValueError, "Invalid function assembly contract: " &
            contract.id)
        if contract.id in usedContracts:
          raise newException(ValueError, "Assembly contract used by multiple functions: " &
            contract.id)
        usedContracts.incl(contract.id)
        functionAssembly.add((if contract.code.startsWith("\""):
          parseJson(contract.code).getStr() else: contract.code) & "\n")
    for contract in module.native:
      if contract.id in usedContracts: continue
      if not freestanding or options.kind notin ["", "exe"] or
          contract.stage != "@asm" or contract.abi != "foo:1":
        raise newException(ValueError,
          "QBE supports module-level @asm contracts only in freestanding executables")
      nativeAssembly.add(contract.code & "\n")
    if uefi and (nativeAssembly.len > 0 or startup.len > 0):
      raise newException(ValueError,
        "UEFI uses efi_main; module startup assembly is unsupported")
    if startup.len > 0:
      if nativeAssembly.len > 0:
        raise newException(ValueError, "Startup function conflicts with module assembly")
      functionAssembly.add("\n.globl _start\n.set _start, " & startup & "\n")
    let bridgeCode = bridgeAbi.bridgeSource(prepared,
      if uefi: "windows-x64" else: options.target)
    let foreignBridge = options.target == "windows-x64" and
      (bridgeCode.contains("foo_qbe_bridge_") or
       bridgeCode.contains("foo_qbe_callback_") or
       bridgeCode.contains("foo_qbe_internal_"))
    if foreignBridge and options.kind notin ["", "exe", "shared"]:
      raise newException(ValueError,
        "Windows foreign ABI adapters require an executable product")
    let integerObject = if freestanding and il.contains("$foo_qbe_integer"):
        integerRuntimeObject(options.target) else: ""
    if integerObject.len > 0:
      let manifestPath = parentDir(integerObject) / "manifest.json"
      if not fileExists(integerObject) or not fileExists(manifestPath):
        raise newException(ValueError,
          "Freestanding integer object is missing; rebuild vendored TinyCC objects")
      let manifest = parseFile(manifestPath)
      if manifest["sourceSha256"].getStr() != hash.digest(runtime) or
          manifest["objects"][options.target].getStr() !=
            hash.checksum(integerObject):
        raise newException(ValueError,
          "Freestanding integer object does not match runtime source")
    if uefi and (il.contains("$foo_qbe_integer") or
        il.contains("$foo_qbe_atomic_") or
        il.contains("$foo_qbe_volatile_")):
      raise newException(ValueError,
        "UEFI wide integer, atomic and volatile helpers need PE-native support")
    let supportedRuntime = il.replace("$foo_qbe_integer", "").replace(
      (if uefi: "$qbe.unused.atomic" else: "$foo_qbe_atomic_"), "").replace(
      (if uefi: "$qbe.unused.volatile" else: "$foo_qbe_volatile_"), "")
    if freestanding and (supportedRuntime.contains("$foo_qbe_") or
        bridgeCode.contains("foo_qbe_")):
      raise newException(ValueError,
        "Freestanding QBE object requires runtime-free source")
    if freestanding and il.contains("$foo_qbe_atomic_"):
      functionAssembly.add("\n" & (case options.target
        of "x64-freestanding": atomicX64
        of "arm64-freestanding": atomicArm64
        of "riscv64-freestanding": atomicRv64
        else: "") & "\n")
    if freestanding and il.contains("$foo_qbe_volatile_"):
      functionAssembly.add("\n" & (case options.target
        of "x64-freestanding": volatileX64
        of "arm64-freestanding": volatileArm64
        of "riscv64-freestanding": volatileRv64
        else: "") & "\n")
    let identity = if toolIdentity.len > 0: toolIdentity
      else: identity(mode, options)
    mark("identity")
    let descriptor = parseJson(identity)
    let destination = absolutePath(directory / artifact(options))
    let metadata = destination & ".qbe.json"
    let cacheKey = hash.digest(identity & "\n" & hash.digest(il) & "\n" &
      hash.digest(bridgeCode) & "\n" & hash.digest(nativeAssembly) & "\n" &
      hash.digest(functionAssembly) & "\n" & hash.digest(attributeIdentity) &
      "\n" & (if integerObject.len > 0: hash.checksum(integerObject) else: "") &
      "\n" & $options)
    let selectedCache = cache.cache(destination, cacheKey)
    result.artifact = destination
    var namedLibraries = false
    for library in options.libs:
      if not fileExists(library): namedLibraries = true
    if not namedLibraries and selectedCache.valid():
      result.success = true
      result.cached = true
      return
    mark("whole-cache")
    let source = absolutePath(directory / "main.ssa")
    let assembly = absolutePath(directory / (if options.target in ["windows-x64", "uefi-x64"]:
      "main-win.s" else: "main-linux.s"))
    let runtimeFile = absolutePath(directory / "qbe-runtime.c")
    let hashmapFile = absolutePath(directory / "qbe-hashmap.h")
    let jsonFile = absolutePath(directory / "qbe-json.h")
    let codecFile = absolutePath(directory / "qbe-codec.h")
    let memoryFile = absolutePath(directory / "qbe-memory.h")
    let traceFile = absolutePath(directory / "trace.c")
    writeFile(source, il)
    if not freestanding:
      writeFile(runtimeFile, runtime & "\n" & bridgeCode)
      writeFile(hashmapFile, sharedHashmap)
      writeFile(jsonFile, sharedJson)
      writeFile(codecFile, qbeCodec)
      writeFile(memoryFile, memoryRuntime)
      writeFile(traceFile, trace)
    let qbeStage = cache.cache(assembly, hash.digest(
      descriptor["qbe"]["path"].getStr() & "\n" &
      descriptor["qbe"]["sha256"].getStr() & "\n" & tools.target &
      "\n" & options.target & "\n" & tools.cc & "\n" &
      descriptor["driverSha256"].getStr() & "\n" &
      hash.digest(il) & "\n" & hash.digest(functionAssembly)))
    var generatedOutput = ""
    if not qbeStage.valid():
      let generated = when defined(windows):
          if tools.qbe.toLowerAscii().endsWith(".exe"):
            execute.captureArgs(tools.qbe,
              @["-t", tools.target, "-o", assembly, source])
          else:
            execute.captureArgs("wsl.exe", @["-d",
              getEnv("FOO_QBE_WSL_DISTRO", "Ubuntu-22.04"), "--",
              guest(tools.qbe), "-t", tools.target, "-o", guest(assembly),
              guest(source)])
        else: execute.captureArgs(tools.qbe,
          @["-t", tools.target, "-o", assembly, source])
      if generated.exitCode != 0:
        raise newException(IOError, "QBE assembly failed: " & generated.output)
      generatedOutput = generated.output
      if freestanding:
        var adjusted = ""
        var aligned = initHashSet[string]()
        for line in readFile(assembly).splitLines():
          for item in prepared.storage:
            if item.alignment > 16 and line == "storage." & item.name & ":":
              adjusted.add(".balign " & $item.alignment & "\n")
              aligned.incl(item.name)
          adjusted.add(line & "\n")
        for item in prepared.storage:
          if item.alignment > 16 and item.name notin aligned:
            raise newException(ValueError,
              "QBE data symbol missing for alignment: " & item.name)
        if aligned.len > 0: writeFile(assembly, adjusted)
      if options.target in ["windows-x64", "uefi-x64"] and
          tools.cc.toLowerAscii().lastPathPart.startsWith("tcc"):
        let emitted = readFile(assembly)
        writeFile(assembly, emitted.replace("\tendbr64\r\n",
          "\t.byte 0xf3,0x0f,0x1e,0xfa\r\n").replace("\tendbr64\n",
          "\t.byte 0xf3,0x0f,0x1e,0xfa\n").replace("\tcallq ",
          "\tcall ").replace("\"Lfp", "Lfp").replace("\"(%rip)", "(%rip)"))
      if options.target == "linux-arm64" and
          tools.cc.toLowerAscii().lastPathPart.startsWith("arm64-tcc"):
        writeFile(assembly, readFile(assembly).replace("\thint\t#34",
          "\t.long 0xd503245f"))
      if options.target == "linux-x64" and linuxTcc(tools.cc, options.target):
        writeFile(assembly, readFile(assembly).replace("\".Lfp", ".Lfp").
          replace("\"(%rip)", "(%rip)"))
      if options.target == "riscv64-freestanding":
        writeFile(assembly, rv64PcRelative(readFile(assembly)))
      if functionAssembly.len > 0:
        writeFile(assembly, readFile(assembly) & functionAssembly)
      qbeStage.save()
    mark("qbe-assembly")
    let bundledTcc = linuxTcc(tools.cc, options.target)
    let linuxKit = if bundledTcc: linuxAssets(tools.cc, options.target)
      else: (headers: "", crt: "", libc: "", libtcc: "")
    let compilerFlags = nativeCompilerFlags(tools.cc, options.target)
    let linuxFlags = compilerFlags.linuxFlags
    let clangTarget = compilerFlags.clangTarget
    let windowsCompiler = quoteShell(tools.cc)
    let windowsAssembly = windowsCompiler & " -c " & quoteShell(assembly) & " -o "
    proc assembleCached(objectFile: string): tuple[output: string, exitCode: int] =
      let stage = cache.cache(objectFile, hash.digest(
        descriptor["assembler"]["path"].getStr() & "\n" &
        descriptor["assembler"]["sha256"].getStr() & "\n" &
        descriptor["cc"]["sha256"].getStr() & "\n" &
        descriptor["compilerSupportSha256"].getStr() & "\n" &
        options.target & "\n" & clangTarget & linuxFlags & "\n" &
        hash.checksum(assembly)))
      if stage.valid(): return (output: "", exitCode: 0)
      result = if options.target in ["windows-x64", "uefi-x64"] and
          tools.cc.toLowerAscii().lastPathPart.startsWith("tcc"):
          execute.captureArgs(tools.cc, @["-c", assembly, "-o", objectFile])
        elif linuxAssembler(tools.cc, options.target).lastPathPart.startsWith("qbe-as") or
            (bundledTcc and options.target == "linux-x64"):
          assembleNative(tools.cc, options.target, assembly, objectFile)
        else:
          execute.capture(if options.target in ["windows-x64", "uefi-x64"]:
              windowsAssembly & quoteShell(objectFile)
            else: quoteShell(tools.cc) & clangTarget & linuxFlags &
              " -c " & quoteShell(assembly) & " -o " & quoteShell(objectFile))
      if result.exitCode == 0: stage.save()
      mark("native-assembly")
    var externalObjects: seq[string]
    for index, path in options.sources:
      let objectPath = absolutePath(directory / ("native-" & $index &
        (if options.target in ["windows-x64", "uefi-x64"]: ".obj" else: ".o")))
      var command = quoteShell(tools.cc) & clangTarget & linuxFlags &
        " -std=c11 -c " & quoteShell(path) & " -o " & quoteShell(objectPath)
      for included in options.includes:
        command.add(" -I " & quoteShell(included))
      for flag in options.flags:
        command.add(" " & quoteShell(flag))
      let compiled = execute.capture(command)
      if compiled.exitCode != 0:
        raise newException(IOError,
          "QBE external source compilation failed: " & compiled.output)
      externalObjects.add(objectPath)
    for path in options.objects: externalObjects.add(absolutePath(path))
    if integerObject.len > 0 and options.kind != "object":
      externalObjects.add(integerObject)
    var externalObjectArgs = ""
    for path in externalObjects:
      externalObjectArgs.add(" " & quoteShell(linkerPath(path, tools.linker)))
    let externalLibraryArgs = nativeLibraries(options, tools.linker)
    var runtimeObject, syscallObject: string
    if not freestanding and options.kind != "object":
      runtimeObject = absolutePath(directory / (if options.target == "windows-x64":
        "qbe-runtime.obj" else: "qbe-runtime.o"))
      let runtimeCache = cache.cache(runtimeObject,
        hash.digest(descriptor["cc"]["path"].getStr() & "\n" &
          descriptor["cc"]["sha256"].getStr() & "\n" &
          descriptor["compilerSupportSha256"].getStr() & "\n" &
          descriptor["runtimeSha256"].getStr() & "\n" &
          hash.checksum(runtimeFile) & "\n" & options.target &
          clangTarget & linuxFlags))
      if not runtimeCache.valid():
        let compiled = if options.target == "windows-x64" and
            tools.cc.toLowerAscii().lastPathPart.startsWith("tcc"):
            execute.captureArgs(tools.cc,
              @["-std=c11", "-O0", "-c", runtimeFile, "-o", runtimeObject])
          else:
            execute.capture(if options.target == "windows-x64":
                windowsCompiler & " -std=c11 -O0 -c " & quoteShell(runtimeFile) &
                  " -o " & quoteShell(runtimeObject)
              else: quoteShell(tools.cc) & clangTarget & linuxFlags &
                " -std=c11 -O0 -c " & quoteShell(runtimeFile) &
                " -o " & quoteShell(runtimeObject))
        if compiled.exitCode != 0:
          raise newException(IOError, "QBE runtime compilation failed: " & compiled.output)
        runtimeCache.save()
      mark("runtime-object")
      if options.target in ["linux-x64", "linux-arm64"]:
        let syscallSource = absolutePath(directory / "qbe-syscall.s")
        syscallObject = absolutePath(directory / "qbe-syscall.o")
        writeFile(syscallSource,
          if options.target == "linux-x64": syscallX64 else: syscallArm64)
        let syscallCache = cache.cache(syscallObject,
          hash.digest(descriptor["assembler"]["path"].getStr() & "\n" &
            descriptor["assembler"]["sha256"].getStr() & "\n" &
            descriptor["compilerSupportSha256"].getStr() & "\n" &
            options.target & "\n" & hash.checksum(syscallSource)))
        if not syscallCache.valid():
          let assembledSyscall = if linuxAssembler(tools.cc,
              options.target).lastPathPart.startsWith("qbe-as") or
              (bundledTcc and options.target == "linux-x64"):
              assembleNative(tools.cc, options.target, syscallSource,
                syscallObject)
            else: execute.capture(quoteShell(tools.cc) & clangTarget &
              linuxFlags & " -c " & quoteShell(syscallSource) & " -o " &
              quoteShell(syscallObject))
          if assembledSyscall.exitCode != 0:
            raise newException(IOError,
              "QBE syscall assembly failed: " & assembledSyscall.output)
          syscallCache.save()
    let linked = if options.kind == "static":
        let objectFile = absolutePath(directory / "module.o")
        let assembled = assembleCached(objectFile)
        if assembled.exitCode != 0:
          raise newException(IOError, "QBE object assembly failed: " & assembled.output)
        if fileExists(destination): removeFile(destination)
        let archiver = if getEnv("FOO_QBE_AR").len > 0:
            quoteShell(getEnv("FOO_QBE_AR"))
          elif bundledTcc: quoteShell(tools.cc) & " -ar"
          else: quoteShell("ar")
        execute.capture(archiver & " rcs " &
          quoteShell(destination) & " " & quoteShell(objectFile) &
          (if runtimeObject.len > 0: " " & quoteShell(runtimeObject) else: "") &
          (if syscallObject.len > 0: " " & quoteShell(syscallObject) else: "") &
          externalObjectArgs)
      elif options.kind == "object":
        assembleCached(destination)
      else:
        let objectFile = absolutePath(directory / (if options.target in ["windows-x64", "uefi-x64"]:
          "main.obj" else: "main.o"))
        let assembled = assembleCached(objectFile)
        if assembled.exitCode != 0:
          raise newException(IOError, "QBE object assembly failed: " & assembled.output)
        if uefi:
          execute.capture(quoteShell(tools.linker) &
            " -nostdlib -Wl,-subsystem=efiapp,-dynamicbase,-e=efi_main " &
            quoteShell(objectFile) & externalObjectArgs &
            externalLibraryArgs & " -o " & quoteShell(destination))
        elif freestanding:
          var nativeObject = ""
          if nativeAssembly.len > 0:
            let nativeSource = absolutePath(directory / "startup.s")
            nativeObject = absolutePath(directory / "startup.o")
            writeFile(nativeSource, nativeAssembly)
            let nativeBuilt = if linuxAssembler(tools.cc,
                options.target).lastPathPart.startsWith("qbe-as"):
                assembleNative(tools.cc, options.target, nativeSource,
                  nativeObject)
              else: execute.capture(quoteShell(tools.cc) & clangTarget &
                " -c " & quoteShell(nativeSource) & " -o " &
                quoteShell(nativeObject))
            if nativeBuilt.exitCode != 0:
              raise newException(IOError,
                "Freestanding startup assembly failed: " & nativeBuilt.output)
          execute.capture(linkerCommand(tools.linker) &
            " --fatal-warnings --no-undefined --gc-sections --build-id=none -z max-page-size=4096 -e _start -o " &
            quoteShell(linkerPath(destination, tools.linker)) &
            (if options.script.len > 0: " -T " &
              quoteShell(linkerPath(options.script, tools.linker)) else: "") &
            (if nativeObject.len > 0: " " &
              quoteShell(linkerPath(nativeObject, tools.linker)) else: "") &
            " " & quoteShell(linkerPath(objectFile, tools.linker)) &
            externalObjectArgs & externalLibraryArgs)
        else:
          if options.kind == "shared":
            if not tools.linker.toLowerAscii().lastPathPart.startsWith("tcc"):
              raise newException(ValueError,
                "QBE Windows shared libraries require vendored TinyCC")
            var exports: seq[string]
            for fn in prepared.funcs:
              if not fn.public: continue
              if fn.abi == "c": exports.add(fn.name)
              elif fn.abi.len == 0: exports.add("foo." & fn.name)
              else:
                raise newException(ValueError,
                  "QBE shared library export requires C or native ABI: " & fn.name)
            if exports.len == 0:
              raise newException(ValueError, "QBE shared library has no public functions")
            let definition = absolutePath(directory / "qbe-exports.def")
            writeFile(definition, "LIBRARY __TCC_SELF__\nEXPORTS\n" &
              exports.join("\n") & "\n")
            let linkedDll = execute.capture(quoteShell(tools.linker) & " -shared " &
              quoteShell(objectFile) & " " & quoteShell(runtimeObject) &
              externalObjectArgs & externalLibraryArgs & " " &
              quoteShell(definition) & " " & quoteShell(winapiDef(tools.cc)) &
              " -o " & quoteShell(destination))
            if linkedDll.exitCode == 0:
              let actual = peExports(destination)
              if actual.len != exports.len:
                raise newException(ValueError,
                  "QBE shared DLL exports differ from public functions")
              for name in exports:
                if name notin actual:
                  raise newException(ValueError,
                    "QBE shared DLL is missing public function '" & name & "'")
            linkedDll
          elif options.target == "windows-x64":
            if externalObjects.len == 0 and options.libs.len == 0 and
                tools.linker.toLowerAscii().lastPathPart.startsWith("tcc"):
              execute.captureArgs(tools.linker, @[objectFile, runtimeObject,
                winapiDef(tools.cc), "-o", destination])
            else:
              execute.capture(quoteShell(tools.linker) & " " & quoteShell(objectFile) &
                " " & quoteShell(runtimeObject) &
                externalObjectArgs & externalLibraryArgs &
                " " & quoteShell(winapiDef(tools.cc)) &
                " -o " & quoteShell(destination))
          elif bundledTcc:
            execute.capture(quoteShell(tools.linker) & " -static -nostdlib" &
              linuxFlags & " " & quoteShell(linuxKit.crt) & " " &
              quoteShell(objectFile) & " " & quoteShell(runtimeObject) & " " &
              quoteShell(syscallObject) & externalObjectArgs &
              externalLibraryArgs & " " & quoteShell(linuxKit.libc) &
              " " & quoteShell(linuxKit.libtcc) &
              " -o " & quoteShell(destination))
          else:
            execute.capture(quoteShell(tools.linker) & " " & quoteShell(objectFile) &
              " " & quoteShell(runtimeObject) &
              (if syscallObject.len > 0: " " & quoteShell(syscallObject) else: "") &
              externalObjectArgs & externalLibraryArgs &
              (if options.target == "linux-arm64": " -static" else: "") &
              " -o " & quoteShell(destination))
    if linked.exitCode != 0:
      raise newException(IOError, "QBE link failed: " & linked.output)
    mark("link")
    var description = parseJson(identity)
    if freestanding:
      description["startupAssemblySha256"] = %hash.digest(nativeAssembly)
    description["functionAssemblySha256"] = %hash.digest(functionAssembly)
    description["functionAttributesSha256"] = %hash.digest(attributeIdentity)
    if integerObject.len > 0:
      description["integerRuntime"] = %*{
        "path": integerObject, "sha256": hash.checksum(integerObject),
        "sourceSha256": hash.digest(runtime)}
    writeFile(metadata, pretty(description) & "\n")
    if not namedLibraries:
      selectedCache.save(@[destination, metadata, source, assembly] &
        (if freestanding: @[] else: @[runtimeFile, traceFile]))
    result.success = true
    result.output = generatedOutput & linked.output
    if progress != nil: progress("compiled", options.name, destination, false)
  except CatchableError as error:
    result.error = error.msg
