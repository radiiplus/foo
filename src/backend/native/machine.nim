import std/strutils
import ../../ir/node
import ../../ir/kind
import ../substrate
import ../../opt/arch

proc machine*(operation: string; params: seq[`Type`]; options: Selection): string =
  let arch = architecture(options.target)
  if operation == "set" or operation == "clear":
    let width = if params.len > 0 and params[0].elem != nil and params[0].elem.width > 0: params[0].elem.width else: 64
    return "if (arg1 >= " & $width & ") abort();\n*arg0 " & (if operation == "set": "|=" else: "&=") & " " & (if operation == "clear": "~" else: "") & "((uint" & $width & "_t)1 << arg1);"
  if operation == "align":
    let pointer = if params.len > 0 and params[0].kind == TypeKind.Slice: "arg0.data" else: "arg0"
    return "if (!arg1 || (arg1 & (arg1 - 1)) || ((uintptr_t)" & pointer & " & (arg1 - 1))) abort();"
  if operation.startsWith("register:"):
    let name = operation[9 .. ^1]
    let registers = if arch == "x86_64": @["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11"]
      elif arch == "aarch64": (block:
        var values: seq[string]
        for index in 0 ..< 16: values.add("x" & $index)
        values)
      elif arch == "riscv64": @["a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "t0", "t1", "t2"]
      else: @[]
    if name notin registers: raise newException(ValueError, "Register '" & name & "' is unavailable on " & arch)
    let instruction = if arch == "x86_64": "movq %0, %%" & name elif arch == "aarch64": "mov " & name & ", %0" else: "mv " & name & ", %0"
    return "__asm__ __volatile__(\"" & instruction & "\" : : \"r\"(arg0) : \"" & name & "\", \"memory\");"
  if operation == "system":
    let target = if options.target.len > 0: options.target else: "host"
    if not target.contains("linux") or arch notin ["x86_64", "aarch64", "riscv64"]: raise newException(ValueError, "Direct system calls are unavailable on " & target & "; use portable system services")
    let registers = if arch == "x86_64": @["rax", "rdi", "rsi", "rdx", "r10", "r8", "r9"] elif arch == "aarch64": @["x8", "x0", "x1", "x2", "x3", "x4", "x5"] else: @["a7", "a0", "a1", "a2", "a3", "a4", "a5"]
    var values: seq[string]
    for index, register in registers: values.add("register uintptr_t value" & $index & " __asm__(\"" & register & "\") = " & (if index < params.len: "(uintptr_t)arg" & $index else: "0") & ";")
    let instruction = if arch == "x86_64": "syscall" elif arch == "aarch64": "svc #0" else: "ecall"
    return values.join("\n") & "\n__asm__ __volatile__(\"" & instruction & "\" : \"+r\"(value0) : : \"memory\");\nreturn (int64_t)value0;"
  raise newException(ValueError, "Unknown machine operation '" & operation & "'")
