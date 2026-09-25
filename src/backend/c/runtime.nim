import std/[sets, strutils, tables]
import ../../ir/[kind, node]
import ../native/service

type RuntimeResult* = object
  code*: string
  libraries*: seq[string]

const
  runtimeSource = staticRead("runtime.h")
  jsonSource = staticRead("json.h")
  httpSource = staticRead("http.h")
  storageSource = staticRead("storage.h")
  streamSource = staticRead("stream.h")

proc member(typ: `Type`): string =
  case typ.kind
  of TypeKind.Void: "unit"
  of TypeKind.Ptr: "pointer"
  of TypeKind.Bool: "boolean"
  of TypeKind.Int, TypeKind.Uint: "number"
  of TypeKind.Slice:
    if typ.elem.width == 16: "wide"
    elif typ.elem.width == 32: "points"
    else: "text"
  else: raise newException(ValueError, "Unsupported C runtime result type")

proc supported(provider, operation: string): bool =
  let operations = {
    "list": @["create", "push", "get", "length", "close"],
    "memory": @["system", "arena", "allocate", "release", "expand", "copy",
      "view", "close", "transfer", "clear", "compare"],
    "stream": @["input", "output", "report", "write", "read", "close", "print"],
    "testing": @["expect", "same", "number", "positive", "real", "point"],
    "system": @["cores", "host", "page"],
    "unicode": @["scan", "next", "release", "valid", "points", "wide", "narrow"],
    "atomic": @["create", "release", "load", "store", "add", "swap", "replace"],
    "buffer": @["free", "words", "points"],
    "crypto": @["hash", "random", "seal", "open", "key", "sign", "verify",
      "password", "confirm"],
    "compress": @["pack", "unpack"],
    "json": @["parse", "write", "field", "item", "quote", "kind", "size",
      "set", "append", "release", "stream", "feed", "next", "data", "close"],
    "http": @["client", "trust", "addHeader", "clearHeaders", "redirects", "reuse", "request", "status", "body", "release",
      "close", "listen", "port", "closeServer", "accept", "receive", "method",
      "header", "read", "reply", "disconnect"]
  }.toTable
  operations.hasKey(provider) and operation in operations[provider]

proc runtime*(externs: seq[Extern];
    typePrinter: proc(value: `Type`): string;
    namePrinter: proc(value: string): string;
    target = ""): RuntimeResult =
  if externs.len == 0:
    return RuntimeResult(code: "static void foo_shutdown(void) {}", libraries: @[])
  let textType = `Type`(kind: TypeKind.Slice, constant: true,
    elem: `Type`(kind: TypeKind.Uint, width: 8))
  let wideType = `Type`(kind: TypeKind.Slice,
    elem: `Type`(kind: TypeKind.Uint, width: 16))
  let pointType = `Type`(kind: TypeKind.Slice,
    elem: `Type`(kind: TypeKind.Uint, width: 32))
  let aliases = "typedef " & typePrinter(textType) & " FOOText;\n" &
    "typedef " & typePrinter(wideType) & " FOOWide;\n" &
    "typedef " & typePrinter(pointType) & " FOOPoints;"
  var modules = initHashSet[string]()
  var wrappers: seq[string]

  for declaration in externs:
    let provider = if declaration.abi == "runtime": "task"
      elif declaration.abi.startsWith("runtime."):
        declaration.abi[8 .. ^1] else: ""
    let operation = if declaration.symbol.len > 0:
      declaration.symbol else: declaration.name
    var parameters: seq[string]
    for index, typ in declaration.params:
      parameters.add(typePrinter(typ) & " p" & $index)
    let signature = "static " & typePrinter(declaration.ret) & " " &
      namePrinter(declaration.name) & "(" &
      (if parameters.len > 0: parameters.join(", ") else: "void") & ")"

    if provider in services:
      modules.incl("service")
      var prefix = ""
      var arguments: seq[string]
      for index, typ in declaration.params:
        arguments.add(if typ.kind == TypeKind.Slice:
          "(FooText){p" & $index & ".data, p" & $index & ".len}"
          else: "p" & $index)
      if provider == "thread" and operation == "spawn":
        let callback = namePrinter(declaration.name) & "_callback"
        let contextType = namePrinter(declaration.name) & "_context"
        prefix = "typedef struct { " & typePrinter(declaration.params[0]) &
          " function; } " & contextType & "; static void " & callback &
          "(void *pointer) { " & contextType &
          " *context = pointer; context->function(); }\n"
        arguments = @[callback, "context"]
      let serviceOperation = if provider == "thread" and operation == "pause":
        "await" else: operation
      let call = "foo_" & provider & "_" & serviceOperation & "(" &
        arguments.join(", ") & ")"
      let returnType = if declaration.ret.kind == TypeKind.Fallible:
        declaration.ret.elem else: declaration.ret
      let returnedValue =
        if returnType.kind == TypeKind.Void: "0"
        elif returnType.kind == TypeKind.Ptr:
          "(" & typePrinter(returnType) & ")result.pointer"
        elif returnType.kind == TypeKind.Slice:
          "(" & typePrinter(returnType) & "){result.text.data, result.text.len}"
        else: "result.number"
      let returned =
        if declaration.ret.kind == TypeKind.Fallible:
          "return (" & typePrinter(declaration.ret) &
            "){foo_service_error(result.error), " & returnedValue & "};"
        elif returnType.kind == TypeKind.Void: "return;"
        else:
          "if (result.error) foo_panic(foo_service_error(result.error)); return " &
            returnedValue & ";"
      let context =
        if provider == "thread" and operation == "spawn":
          namePrinter(declaration.name) &
            "_context *context = foo_owned(sizeof(*context)); if (!context) return (" &
            typePrinter(declaration.ret) &
            "){\"OutOfMemory\", 0}; context->function = p0;"
        else: ""
      wrappers.add(prefix & signature & " { " & context &
        " FooResult result = " & call & "; " & returned & " }")
      continue

    if provider == "sequence":
      if operation == "create":
        wrappers.add(signature & " { return (" & typePrinter(declaration.ret) & "){0}; }")
      elif operation == "length":
        wrappers.add(signature & " { return p0.len; }")
      elif operation == "sized":
        let sliceType = typePrinter(declaration.ret.elem)
        let elementType = typePrinter(declaration.ret.elem.elem)
        wrappers.add(signature & " { if (p0 > SIZE_MAX / sizeof(" & elementType &
          ")) return (" & typePrinter(declaration.ret) &
          "){\"Overflow\", {0}}; size_t count = (size_t)p0; if (!count) return (" &
          typePrinter(declaration.ret) & "){0}; " & elementType &
          " *items = foo_owned(count * sizeof(*items)); if (!items) return (" &
          typePrinter(declaration.ret) &
          "){\"OutOfMemory\", {0}}; memset(items, 0, count * sizeof(*items)); return (" &
          typePrinter(declaration.ret) & "){0, (" & sliceType & "){items, count}}; }")
      elif operation == "compact":
        let sliceType = typePrinter(declaration.ret.elem)
        let elementType = typePrinter(declaration.ret.elem.elem)
        wrappers.add(signature & " { if (p1 > p0.len) return (" &
          typePrinter(declaration.ret) &
          "){\"Bounds\", {0}}; if (p1 == p0.len) return (" &
          typePrinter(declaration.ret) & "){0, p0}; size_t count = (size_t)p1; " &
          elementType & " *items = 0; if (count) { items = foo_owned(count * sizeof(*items)); if (!items) return (" &
          typePrinter(declaration.ret) &
          "){\"OutOfMemory\", {0}}; foo_transfer(items, p0.data, count * sizeof(*items)); } " &
          "FOOResult released = foo_buffer_free((FOOText){(const uint8_t*)p0.data, p0.len * sizeof(*p0.data)}); " &
          "if (released.error) { if (items) (void)foo_buffer_free((FOOText){(const uint8_t*)items, count * sizeof(*items)}); return (" &
          typePrinter(declaration.ret) & "){released.error, {0}}; } return (" &
          typePrinter(declaration.ret) & "){0, (" & sliceType & "){items, count}}; }")
      elif operation == "release":
        wrappers.add(signature &
          " { FOOResult result = foo_buffer_free((FOOText){(const uint8_t*)p0.data, p0.len * sizeof(*p0.data)}); return (" &
          typePrinter(declaration.ret) & "){result.error, 0}; }")
      else:
        if operation notin ["copy", "append", "remove"]:
          raise newException(ValueError, "Unknown sequence operation '" & operation & "'")
        let sliceType = typePrinter(declaration.ret.elem)
        let elementType = typePrinter(declaration.ret.elem.elem)
        let count =
          if operation == "append": "p0.len + 1"
          elif operation == "remove": "p0.len - 1"
          else: "p0.len"
        let guard = if operation == "remove":
          "if (p1 >= p0.len) return (" & typePrinter(declaration.ret) &
            "){\"Bounds\", {0}};" else: ""
        let copying =
          if operation == "remove":
            "if (p1) foo_transfer(items, p0.data, p1 * sizeof(*items)); if (p0.len > p1 + 1) foo_transfer(items + p1, p0.data + p1 + 1, (p0.len - p1 - 1) * sizeof(*items));"
          else:
            "if (p0.len) foo_transfer(items, p0.data, p0.len * sizeof(*items)); " &
              (if operation == "append": "items[p0.len] = p1;" else: "")
        wrappers.add(signature & " { " & guard &
          " if (p0.len >= SIZE_MAX / sizeof(" & elementType &
          ")) return (" & typePrinter(declaration.ret) &
          "){\"Overflow\", {0}}; size_t count = " & count &
          "; if (!count) return (" & typePrinter(declaration.ret) &
          "){0}; " & elementType &
          " *items = foo_owned(count * sizeof(*items)); if (!items) return (" &
          typePrinter(declaration.ret) &
          "){\"OutOfMemory\", {0}}; " & copying & " return (" &
          typePrinter(declaration.ret) & "){0, (" & sliceType &
          "){items, count}}; }")
      continue

    if provider == "hashmap":
      modules.incl("hashmap")
      let returnType = if declaration.ret.kind == TypeKind.Fallible:
        declaration.ret.elem else: declaration.ret
      var call = ""
      case operation
      of "create": call = "foo_hashmap_create()"
      of "put":
        call = "foo_hashmap_put(p0, (FOOText){p1.data, p1.len}, &p2, sizeof(p2))"
      of "get": call = "foo_hashmap_get(p0, (FOOText){p1.data, p1.len})"
      of "contains": call = "foo_hashmap_contains(p0, (FOOText){p1.data, p1.len})"
      of "remove": call = "foo_hashmap_remove(p0, (FOOText){p1.data, p1.len})"
      of "length": call = "foo_hashmap_length(p0)"
      of "close": call = "foo_hashmap_close(p0)"
      else: raise newException(ValueError, "Unknown hashmap operation '" & operation & "'")
      var value = "0"
      if operation == "create": value = "(" & typePrinter(returnType) & ")result.pointer"
      elif operation == "get": value = "*(" & typePrinter(returnType) & "*)result.pointer"
      elif operation in ["contains", "remove"]: value = "result.boolean"
      elif operation == "length": value = "result.number"
      let body = "foo_enter(); FOOResult result = " & call &
        "; foo_leave(); return (" & typePrinter(declaration.ret) &
        "){result.error, " & value & "};"
      wrappers.add(signature & " { " & body & " }")
      continue

    if not supported(provider, operation):
      raise newException(ValueError, "C backend does not yet implement " &
        (if provider.len > 0: provider else: "task") & "." & operation)
    modules.incl(provider)
    var arguments: seq[string]
    for index, typ in declaration.params:
      if typ.kind == TypeKind.Optional:
        arguments.add("(FOONext){p" & $index & ".present, p" & $index & ".value}")
      elif provider == "memory" and typ.kind == TypeKind.Slice:
        arguments.add("(FOOText){p" & $index & ".data, p" & $index & ".len}")
      else:
        arguments.add("p" & $index)
    let call = "foo_" & provider & "_" & operation & "(" & arguments.join(", ") & ")"
    let locked = provider in ["list", "memory", "stream"] and not
      (provider == "memory" and operation in ["transfer", "clear", "compare"])
    let leave = if locked: "foo_leave();" else: ""
    var body: string
    if declaration.ret.kind == TypeKind.Fallible:
      body = "FOOResult result = " & call & "; " & leave & " return (" &
        typePrinter(declaration.ret) & "){ result.error, " &
        (if declaration.ret.elem.kind == TypeKind.Ptr:
          "(" & typePrinter(declaration.ret.elem) & ")" else: "") &
        "result." & member(declaration.ret.elem) & " };"
    elif declaration.ret.kind == TypeKind.Optional:
      body = "FOONext result = " & call & "; return (" &
        typePrinter(declaration.ret) & "){result.present, result.value};"
    elif declaration.ret.kind == TypeKind.Void:
      body = call & "; " & leave
    else:
      body = typePrinter(declaration.ret) & " result = " & call & "; " &
        leave & " return result;"
    if locked: body = "foo_enter(); " & body
    wrappers.add(signature & " { " & body & " }")

  var defines: seq[string]
  for provider in modules:
    defines.add("#define FOO_" & provider.toUpperAscii & " 1")
  let serviceCode = if "service" in modules:
    "#include \"service.h\"\nstatic const char *foo_service_error(int code) { static const char *names[] = {NULL, \"OutOfMemory\", \"InvalidInput\", \"IoFailure\", \"Closed\", \"MissingValue\", \"SystemFailure\", \"Bounds\"}; return code >= 0 && code < 8 ? names[code] : \"SystemFailure\"; }\n"
    else: ""
  let header = runtimeSource
    .replace("#include \"json.h\"", jsonSource)
    .replace("#include \"http.h\"", httpSource)
    .replace("#include \"storage.h\"", storageSource)
    .replace("#include \"stream.h\"", streamSource)
  result.code = aliases & "\n" & defines.join("\n") & "\n" &
    serviceCode & header & "\n" & wrappers.join("\n")
  if "crypto" in modules: result.libraries.add("sodium")
  if "compress" in modules: result.libraries.add("z")
  if "http" in modules:
    if target.contains("windows") or target.contains("win32") or
        (target.len == 0 and defined(windows)):
      result.libraries.add("winhttp")
      result.libraries.add("ws2_32")
    else:
      result.libraries.add("curl")
