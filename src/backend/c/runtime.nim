import std/[sets, strutils, tables]
import ../../ir/[kind, node]
import ../native/service

type RuntimeResult* = object
  code*: string
  libraries*: seq[string]

const
  runtimeSource = staticRead("runtime.h")
  archSource = staticRead("arch.h")
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

proc castable(typ: `Type`): bool =
  if typ == nil: return false
  case typ.kind
  of TypeKind.Int, TypeKind.Uint, TypeKind.Float: true
  of TypeKind.ExternStruct:
    if typ.fields.len == 0: return false
    for field in typ.fields.values:
      if not castable(field): return false
    true
  else: false

proc supported(provider, operation: string): bool =
  let operations = {
    "arch": @["count", "tally", "combine", "pause", "ticks", "target", "prefetch", "stage"],
    "list": @["create", "push", "get", "length", "close"],
    "memory": @["system", "arena", "allocate", "reserve", "aligned",
      "release", "expand", "copy", "view", "bytes", "close", "transfer",
      "clear", "compare", "identical"],
    "stream": @["input", "output", "report", "write", "read", "close", "print"],
    "testing": @["expect", "same", "number", "positive", "real", "point"],
    "system": @["cores", "host", "page"],
    "unicode": @["scan", "next", "release", "valid", "points", "wide", "narrow"],
    "atomic": @["create", "release", "load", "store", "add", "deduct", "swap", "replace", "compare"],
    "buffer": @["free", "words", "points"],
    "binary": @["octet", "widen", "encode", "scan", "next", "fixed", "parse",
      "zigzag", "unfold", "hex", "unpack", "base64", "restore"],
    "checksum": @["compute", "begin", "update", "result", "close"],
    "crypto": @["hash", "digest", "hex", "begin", "update",
      "finalize", "result", "close", "auth", "absorb", "tag", "check",
      "discard", "derive", "compare", "random", "seal", "open",
      "key", "sign", "verify", "password", "confirm", "blake",
      "fingerprint", "initiate", "append", "extract",
      "render", "retire", "reproduce", "available", "wrap",
      "unwrap", "protect", "shield", "reveal", "forget"],
    "compress": @["pack", "unpack", "header", "extent"],
    "json": @["parse", "write", "field", "item", "quote", "kind", "size",
      "set", "append", "release", "stream", "feed", "next", "data", "close"],
    "http": @["client", "trust", "attach", "clear", "redirects", "reuse", "request", "status", "body", "release",
      "close", "listen", "port", "shutdown", "accept", "receive", "method",
      "header", "read", "reply", "disconnect"]
  }.toTable
  operations.hasKey(provider) and operation in operations[provider]

proc runtime*(externs: seq[Extern];
    typePrinter: proc(value: `Type`): string;
    namePrinter: proc(value: string): string;
    target = ""; hosted = true): RuntimeResult =
  if externs.len == 0:
    if not hosted: return RuntimeResult()
    return RuntimeResult(code:
      "static void foo_benchmark_report(void) { fprintf(stderr, \"FOO_METRICS {\\\"allocations\\\":0,\\\"allocatedBytes\\\":0,\\\"reallocations\\\":0,\\\"bytesCopied\\\":0,\\\"growthOperations\\\":0,\\\"growthBytesCopied\\\":0,\\\"averageCapacity\\\":0.0,\\\"maximumCapacity\\\":0,\\\"growthFactor\\\":0.0,\\\"liveBytes\\\":0,\\\"peakBytes\\\":0,\\\"olderVersionBytes\\\":0,\\\"slowPathHits\\\":0,\\\"branchOperations\\\":0,\\\"branchBytesCopied\\\":0}\\n\"); }\n" &
      "static void foo_shutdown(void) {}", libraries: @[])
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

  proc write(typ: `Type`; value: string; serial: var int): string
  proc write(typ: `Type`; value: string; serial: var int): string =
    if typ == nil: raise newException(ValueError, "Codec needs a concrete type")
    case typ.kind
    of TypeKind.Bool:
      result = "foo_put(&writer, " & value & " ? \"true\" : \"false\", " &
        value & " ? 4 : 5);"
    of TypeKind.Int, TypeKind.Uint, TypeKind.Float:
      inc serial
      let buffer = "number" & $serial
      let count = "count" & $serial
      if typ.kind in {TypeKind.Int, TypeKind.Uint} and typ.width > 64:
        let number = "wide" & $serial
        let magnitude = "magnitude" & $serial
        let cursor = "cursor" & $serial
        let negative = "negative" & $serial
        let signed = typ.kind == TypeKind.Int
        result = "char " & buffer & "[64]; size_t " & cursor & " = sizeof(" &
          buffer & "); " & (if signed:
            "foo_i128 " & number & " = (foo_i128)(" & value & "); bool " &
              negative & " = " & number & " < 0; foo_u128 " & magnitude &
              " = " & negative & " ? (foo_u128)(-(" & number &
              " + 1)) + 1 : (foo_u128)" & number & ";"
            else:
              "bool " & negative & " = false; foo_u128 " & magnitude &
              " = (foo_u128)(" & value & ");") &
          " do { " & buffer & "[--" & cursor & "] = (char)('0' + " &
          magnitude & " % 10); " & magnitude & " /= 10; } while (" &
          magnitude & "); if (" & negative & ") " & buffer & "[--" & cursor &
          "] = '-'; foo_put(&writer, " & buffer & " + " & cursor &
          ", sizeof(" & buffer & ") - " & cursor & ");"
        return
      let format = if typ.kind == TypeKind.Int: "%lld"
        elif typ.kind == TypeKind.Uint: "%llu" else: "%.17g"
      let conversion = if typ.kind == TypeKind.Int: "(long long)"
        elif typ.kind == TypeKind.Uint: "(unsigned long long)" else: "(double)"
      result = "char " & buffer & "[64]; int " & count & " = snprintf(" &
        buffer & ", sizeof(" & buffer & "), \"" & format & "\", " & conversion &
        value & "); if (" & count & " < 0 || (size_t)" & count & " >= sizeof(" &
        buffer & ")) { codec_error = \"NumberOverflow\"; goto codec_failed; } " &
        "foo_put(&writer, " & buffer & ", (size_t)" & count & ");"
    of TypeKind.Slice:
      if typ.constant and typ.elem != nil and typ.elem.kind == TypeKind.Uint and
          typ.elem.width == 8:
        result = "if (!foo_unicode_valid((FOOText){" & value & ".data, " & value &
          ".len})) { codec_error = \"InvalidUtf8\"; goto codec_failed; } " &
          "foo_quote(&writer, (FOOText){" & value & ".data, " & value & ".len});"
      else:
        if typ.elem == nil:
          raise newException(ValueError, "Codec sequence needs a concrete element type")
        inc serial
        let index = "index" & $serial
        result = "foo_put(&writer, \"[\", 1); for (size_t " & index &
          " = 0; " & index & " < " & value & ".len; " & index & "++) { " &
          "if (" & index & ") foo_put(&writer, \",\", 1); "
        result.add(write(typ.elem, value & ".data[" & index & "]", serial))
        result.add(" } foo_put(&writer, \"]\", 1);")
    of TypeKind.Optional:
      if typ.elem == nil:
        raise newException(ValueError, "Codec optional needs a concrete value type")
      result = "if (!" & value & ".present) { foo_put(&writer, \"null\", 4); } else { "
      result.add(write(typ.elem, value & ".value", serial))
      result.add(" }")
    of TypeKind.TaggedUnion:
      result = "switch ((" & value & ").tag) { "
      var index = 0
      for variant, variantType in typ.variants:
        result.add("case " & $index & ": foo_put(&writer, \"{\", 1); " &
          "foo_quote(&writer, (FOOText){(const uint8_t *)\"" & variant &
          "\", " & $variant.len & "}); foo_put(&writer, \":\", 1); ")
        if variantType == nil or variantType.kind == TypeKind.Void:
          result.add("foo_put(&writer, \"{}\", 2);")
        else:
          result.add(write(variantType, "(" & value & ").payload." &
            namePrinter(variant), serial))
        result.add(" foo_put(&writer, \"}\", 1); break; ")
        inc index
      result.add("default: codec_error = \"InvalidChoice\"; goto codec_failed; }")
    of TypeKind.Struct, TypeKind.ExternStruct:
      result = "foo_put(&writer, \"{\", 1);"
      var index = 0
      for field, fieldType in typ.fields:
        if index > 0: result.add("foo_put(&writer, \",\", 1);")
        result.add("foo_quote(&writer, (FOOText){(const uint8_t *)\"" & field &
          "\", " & $field.len & "}); foo_put(&writer, \":\", 1);")
        result.add(write(fieldType, value & "." & namePrinter(field), serial))
        inc index
      result.add("foo_put(&writer, \"}\", 1);")
    else:
      raise newException(ValueError, "Codec does not support " & $typ.kind)

  proc read(typ: `Type`; target, source: string; serial: var int): string
  proc read(typ: `Type`; target, source: string; serial: var int): string =
    if typ == nil: raise newException(ValueError, "Codec needs a concrete type")
    case typ.kind
    of TypeKind.Bool:
      result = "if (" & source & "->kind != 't' && " & source &
        "->kind != 'f') { codec_error = \"ExpectedBoolean\"; goto codec_failed; } " &
        target & " = " & source & "->kind == 't';"
    of TypeKind.Int, TypeKind.Uint:
      inc serial
      let number = "number" & $serial
      let ending = "ending" & $serial
      let signed = typ.kind == TypeKind.Int
      if typ.width > 64:
        let index = "index" & $serial
        let digit = "digit" & $serial
        let negative = "negative" & $serial
        let limit = "limit" & $serial
        let positiveLimit = "(((foo_u128)1 << " & $(typ.width - 1) & ") - 1)"
        let negativeLimit = "((foo_u128)1 << " & $(typ.width - 1) & ")"
        let unsignedLimit = if typ.width == 128: "~(foo_u128)0"
          else: "(((foo_u128)1 << " & $typ.width & ") - 1)"
        result = "if (" & source & "->kind != 'd') { codec_error = \"ExpectedNumber\"; goto codec_failed; } " &
          "bool " & negative & " = " & source & "->raw.len && " & source &
          "->raw.data[0] == '-'; " & (if not signed:
            "if (" & negative & ") { codec_error = \"NumberOverflow\"; goto codec_failed; } "
            else: "") & "size_t " & index & " = " & negative & " ? 1 : 0; " &
          "if (" & index & " == " & source &
          "->raw.len) { codec_error = \"NumberOverflow\"; goto codec_failed; } " &
          "foo_u128 " & number & " = 0; const foo_u128 " & limit & " = " &
          (if signed: "(" & negative & " ? " & negativeLimit & " : " &
            positiveLimit & ")" else: unsignedLimit) & "; for (; " & index &
          " < " & source & "->raw.len; " & index & "++) { uint8_t " & digit &
          " = " & source & "->raw.data[" & index & "]; if (" & digit &
          " < '0' || " & digit & " > '9') { codec_error = \"NumberOverflow\"; goto codec_failed; } " &
          digit & " = (uint8_t)(" & digit & " - '0'); if (" & number & " > (" &
          limit & " - " & digit & ") / 10) { codec_error = \"NumberOverflow\"; goto codec_failed; } " &
          number & " = " & number & " * 10 + " & digit & "; } "
        if signed:
          result.add(target & " = " & negative & " ? (" & number &
            " ? -((foo_i128)(" & number & " - 1)) - 1 : 0) : (foo_i128)" &
            number & ";")
        else:
          result.add(target & " = (foo_u128)" & number & ";")
        return
      result = "if (" & source & "->kind != 'd') { codec_error = \"ExpectedNumber\"; goto codec_failed; } " &
        (if not signed: "if (" & source & "->raw.len && " & source &
          "->raw.data[0] == '-') { codec_error = \"NumberOverflow\"; goto codec_failed; } " else: "") &
        "errno = 0; char *" & ending & " = NULL; " &
        (if signed: "long long " else: "unsigned long long ") & number & " = " &
        (if signed: "strtoll" else: "strtoull") & "((const char *)" & source &
        "->raw.data, &" & ending & ", 10); if (errno || " & ending &
        " != (const char *)" & source & "->raw.data + " & source &
        "->raw.len) { codec_error = \"NumberOverflow\"; goto codec_failed; } "
      if typ.width > 0 and typ.width < 64:
        let limit = if signed:
          "(" & number & " < -(INT64_C(1) << " & $(typ.width - 1) & ") || " &
            number & " > (INT64_C(1) << " & $(typ.width - 1) & ") - 1)"
          else:
            "(" & number & " > (UINT64_C(1) << " & $typ.width & ") - 1)"
        result.add("if " & limit & " { codec_error = \"NumberOverflow\"; goto codec_failed; } ")
      result.add(target & " = (" & typePrinter(typ) & ")" & number & ";")
    of TypeKind.Float:
      inc serial
      let number = "number" & $serial
      let ending = "ending" & $serial
      result = "if (" & source & "->kind != 'd') { codec_error = \"ExpectedNumber\"; goto codec_failed; } " &
        "errno = 0; char *" & ending & " = NULL; double " & number &
        " = strtod((const char *)" & source & "->raw.data, &" & ending &
        "); if (errno || " & ending & " != (const char *)" & source &
        "->raw.data + " & source & "->raw.len) { codec_error = \"NumberOverflow\"; goto codec_failed; } " &
        target & " = (" & typePrinter(typ) & ")" & number & ";"
    of TypeKind.Slice:
      if typ.constant and typ.elem != nil and typ.elem.kind == TypeKind.Uint and
          typ.elem.width == 8:
        inc serial
        let copied = "copied" & $serial
        result = "if (" & source & "->kind != 's') { codec_error = \"ExpectedText\"; goto codec_failed; } " &
          "FOOResult " & copied & " = foo_copy(" & source & "->raw.data, " & source &
          "->raw.len); if (" & copied & ".error) { codec_error = " & copied &
          ".error; goto codec_failed; } " & target & " = (" & typePrinter(typ) &
          "){" & copied & ".text.data, " & copied & ".text.len};"
      else:
        if typ.elem == nil:
          raise newException(ValueError, "Codec sequence needs a concrete element type")
        inc serial
        let count = "count" & $serial
        let child = "item" & $serial
        let index = "index" & $serial
        let items = "items" & $serial
        let elementType = typePrinter(typ.elem)
        result = "if (" & source & "->kind != '[') { codec_error = \"ExpectedSequence\"; goto codec_failed; } " &
          "size_t " & count & " = 0; for (FOOJson *" & child & " = " & source &
          "->child; " & child & "; " & child & " = " & child & "->next) { if (" &
          count & " == SIZE_MAX) { codec_error = \"Overflow\"; goto codec_failed; } " &
          count & "++; } if (" & count & " > SIZE_MAX / sizeof(" & elementType &
          ")) { codec_error = \"Overflow\"; goto codec_failed; } " & elementType &
          " *" & items & " = NULL; if (" & count & ") { " & items &
          " = foo_sequence_owned(sizeof(*" & items & "), " & count & ", " & count &
          "); if (!" & items & ") { codec_error = \"OutOfMemory\"; goto codec_failed; } } " &
          "size_t " & index & " = 0; for (FOOJson *" & child & " = " & source &
          "->child; " & child & "; " & child & " = " & child & "->next, " & index &
          "++) { "
        result.add(read(typ.elem, items & "[" & index & "]", child, serial))
        result.add(" } " & target & " = (" & typePrinter(typ) & "){" & items &
          ", " & count & "};")
    of TypeKind.Optional:
      if typ.elem == nil:
        raise newException(ValueError, "Codec optional needs a concrete value type")
      result = "if (" & source & "->kind == 'n') { " & target & " = (" &
        typePrinter(typ) & "){0}; } else { " & target & ".present = true; "
      result.add(read(typ.elem, target & ".value", source, serial))
      result.add(" }")
    of TypeKind.TaggedUnion:
      inc serial
      let variant = "variant" & $serial
      result = "if (" & source & "->kind != '{') { codec_error = \"ExpectedChoice\"; goto codec_failed; } " &
        "FOOJson *" & variant & " = " & source & "->child; if (!" & variant &
        " || " & variant & "->next) { codec_error = \"ExpectedChoice\"; goto codec_failed; } "
      var index = 0
      for variantName, variantType in typ.variants:
        result.add((if index == 0: "if (" else: " else if (") & variant &
          "->key.len == " & $variantName.len & " && !memcmp(" & variant &
          "->key.data, \"" & variantName & "\", " & $variantName.len & ")) { " &
          "(" & target & ").tag = " & $index & "; ")
        if variantType == nil or variantType.kind == TypeKind.Void:
          result.add("if (" & variant & "->kind != '{' || " & variant &
            "->child) { codec_error = \"ExpectedChoicePayload\"; goto codec_failed; }")
        else:
          result.add(read(variantType, "(" & target & ").payload." &
            namePrinter(variantName), variant, serial))
        result.add(" }")
        inc index
      result.add(" else { codec_error = \"UnknownVariant\"; goto codec_failed; }")
    of TypeKind.Struct, TypeKind.ExternStruct:
      result = "if (" & source & "->kind != '{') { codec_error = \"ExpectedObject\"; goto codec_failed; }"
      for field, fieldType in typ.fields:
        inc serial
        let child = "child" & $serial
        result.add("FOOJson *" & child & " = " & source & "->child; while (" & child &
          " && (" & child & "->key.len != " & $field.len & " || memcmp(" & child &
          "->key.data, \"" & field & "\", " & $field.len & "))) " & child &
          " = " & child & "->next; if (!" & child &
          ") { codec_error = \"MissingField\"; goto codec_failed; }")
        result.add(read(fieldType, target & "." & namePrinter(field), child, serial))
    else:
      raise newException(ValueError, "Codec does not support " & $typ.kind)

  for declaration in externs:
    let provider = if declaration.abi == "runtime": "task"
      elif declaration.abi.startsWith("runtime."):
        declaration.abi[8 .. ^1] else: ""
    let operation = if declaration.symbol.len > 0:
      declaration.symbol else: declaration.name
    if not hosted and provider != "arch":
      raise newException(ValueError, provider & "." & operation &
        " requires the hosted runtime")
    var parameters: seq[string]
    for index, typ in declaration.params:
      parameters.add(typePrinter(typ) & " p" & $index)
    let signature = "static " & typePrinter(declaration.ret) & " " &
      namePrinter(declaration.name) & "(" &
      (if parameters.len > 0: parameters.join(", ") else: "void") & ")"

    if provider == "resource" and operation == "heap":
      wrappers.add(signature & " { return foo_heap_bytes(); }")
      continue
    if provider == "text" and operation == "release":
      modules.incl("service")
      wrappers.add(signature & " { FOOResult local = foo_free(p0.data, p0.len); " &
        "if (!local.error || strcmp(local.error, \"UnknownBuffer\") != 0) " &
        "return (" & typePrinter(declaration.ret) & "){local.error, 0}; " &
        "FooResult remote = foo_text_release((FooText){p0.data, p0.len}); " &
        "return (" & typePrinter(declaration.ret) & "){foo_service_error(remote.error), 0}; }")
      continue
    if provider == "memory" and operation == "reinterpret":
      if declaration.params.len != 3 or declaration.ret == nil or
          declaration.ret.kind != TypeKind.Failable or
          declaration.ret.elem.kind != TypeKind.Ptr or
          not castable(declaration.ret.elem.elem):
        raise newException(ValueError,
          "memory.cast requires a scalar or scalar-only C record")
      modules.incl("memory")
      let target = typePrinter(declaration.ret.elem.elem)
      wrappers.add(signature & " { FOOResult result = foo_memory_reinterpret(" &
        "p0, p1, p2, sizeof(" & target & "), _Alignof(" & target & ")); " &
        "return (" & typePrinter(declaration.ret) & "){result.error, (" &
        typePrinter(declaration.ret.elem) & ")result.pointer}; }")
      continue
    if provider in services and provider != "testing":
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
      let returnType = if declaration.ret.kind == TypeKind.Failable:
        declaration.ret.elem else: declaration.ret
      let returnedValue =
        if returnType.kind == TypeKind.Void: "0"
        elif returnType.kind == TypeKind.Ptr:
          "(" & typePrinter(returnType) & ")result.pointer"
        elif returnType.kind == TypeKind.Slice:
          "(" & typePrinter(returnType) & "){result.text.data, result.text.len}"
        elif returnType.kind == TypeKind.Optional:
          "(" & typePrinter(returnType) & "){result.pointer != NULL, result.number}"
        else: "result.number"
      let returned =
        if declaration.ret.kind == TypeKind.Failable:
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

    if provider == "codec":
      modules.incl("json")
      modules.incl("codec")
      var serial = 0
      if operation in ["encode", "marshal"]:
        if declaration.params.len != 1 or declaration.ret == nil or
            declaration.ret.kind != TypeKind.Failable or
            declaration.ret.elem.kind != TypeKind.Slice:
          raise newException(ValueError, "codec.encode needs one value and a failable text result")
        let body = write(declaration.params[0], "p0", serial)
        wrappers.add(signature & " { const char *codec_error = NULL; FOOWriter writer = {0}; " &
          body & " if (writer.failed || !foo_adopt(writer.data, writer.length)) " &
          "codec_error = \"OutOfMemory\"; if (codec_error) goto codec_failed; return (" &
          typePrinter(declaration.ret) & "){NULL, (" & typePrinter(declaration.ret.elem) &
          "){writer.data, writer.length}}; codec_failed: free(writer.data); return (" &
          typePrinter(declaration.ret) & "){codec_error, {0}}; }")
      elif operation in ["decode", "unmarshal"]:
        if declaration.params.len != 1 or declaration.ret == nil or
            declaration.ret.kind != TypeKind.Failable:
          raise newException(ValueError, "codec.decode needs text and a failable concrete result")
        let body = read(declaration.ret.elem, "value", "root", serial)
        wrappers.add(signature & " { FOOResult parsed = foo_json_parse((FOOText){p0.data, p0.len}); " &
          "if (parsed.error) return (" & typePrinter(declaration.ret) & "){parsed.error, {0}}; " &
          typePrinter(declaration.ret.elem) & " value = {0}; const char *codec_error = NULL; " &
          "FOOJson *root = parsed.pointer; " & body &
          " foo_json_release(root); return (" & typePrinter(declaration.ret) & "){NULL, value}; " &
          "codec_failed: foo_json_release(root); return (" & typePrinter(declaration.ret) &
          "){codec_error, {0}}; }")
      else:
        raise newException(ValueError, "Unknown codec operation '" & operation & "'")
      continue

    if provider == "sequence":
      if operation == "create":
        wrappers.add(signature & " { return (" & typePrinter(declaration.ret) & "){0}; }")
      elif operation in ["length", "extent"]:
        wrappers.add(signature & " { return p0.len; }")
      elif operation == "view":
        let sliceType = typePrinter(declaration.ret.elem)
        wrappers.add(signature & " { if (p1 > p0.len || p2 > p0.len - p1) return (" &
          typePrinter(declaration.ret) & "){\"Bounds\", {0}}; return (" &
          typePrinter(declaration.ret) & "){0, (" & sliceType &
          "){p0.data ? p0.data + p1 : 0, (size_t)p2}}; }")
      elif operation == "sized":
        let sliceType = typePrinter(declaration.ret.elem)
        let elementType = typePrinter(declaration.ret.elem.elem)
        wrappers.add(signature & " { if (p0 > SIZE_MAX / sizeof(" & elementType &
          ")) return (" & typePrinter(declaration.ret) &
          "){\"Overflow\", {0}}; size_t count = (size_t)p0; if (!count) return (" &
          typePrinter(declaration.ret) & "){0}; " & elementType &
          " *items = foo_sequence_owned(sizeof(*items), count, count); if (!items) return (" &
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
          elementType & " *items = 0; if (count) { items = foo_sequence_owned(sizeof(*items), count, count); if (!items) return (" &
          typePrinter(declaration.ret) &
          "){\"OutOfMemory\", {0}}; foo_transfer(items, p0.data, count * sizeof(*items)); } " &
          "FOOResult released = foo_sequence_free(p0.data, p0.len, sizeof(*p0.data)); " &
          "if (released.error) { if (items) (void)foo_sequence_free(items, count, sizeof(*items)); return (" &
          typePrinter(declaration.ret) & "){released.error, {0}}; } return (" &
          typePrinter(declaration.ret) & "){0, (" & sliceType & "){items, count}}; }")
      elif operation == "release":
        wrappers.add(signature &
          " { FOOResult result = foo_sequence_free(p0.data, p0.len, sizeof(*p0.data)); return (" &
          typePrinter(declaration.ret) & "){result.error, 0}; }")
      elif operation == "append":
        let sliceType = typePrinter(declaration.ret.elem)
        let elementType = typePrinter(declaration.ret.elem.elem)
        wrappers.add(signature & " { FOOResult result = foo_sequence_append(p0.data, p0.len, sizeof(" &
          elementType & "), &p1); return (" & typePrinter(declaration.ret) &
          "){result.error, (" & sliceType & "){(" & elementType &
          "*)result.text.data, result.text.len}}; }")
      else:
        if operation notin ["copy", "remove"]:
          raise newException(ValueError, "Unknown sequence operation '" & operation & "'")
        let sliceType = typePrinter(declaration.ret.elem)
        let elementType = typePrinter(declaration.ret.elem.elem)
        let count =
          if operation == "remove": "p0.len - 1"
          else: "p0.len"
        let guard = if operation == "remove":
          "if (p1 >= p0.len) return (" & typePrinter(declaration.ret) &
            "){\"Bounds\", {0}};" else: ""
        let copying =
          if operation == "remove":
            "if (p1) foo_transfer(items, p0.data, p1 * sizeof(*items)); if (p0.len > p1 + 1) foo_transfer(items + p1, p0.data + p1 + 1, (p0.len - p1 - 1) * sizeof(*items));"
          else:
            "if (p0.len) foo_transfer(items, p0.data, p0.len * sizeof(*items)); "
        wrappers.add(signature & " { " & guard &
          " if (p0.len >= SIZE_MAX / sizeof(" & elementType &
          ")) return (" & typePrinter(declaration.ret) &
          "){\"Overflow\", {0}}; " &
          " size_t count = " & count &
          "; if (!count) return (" & typePrinter(declaration.ret) &
          "){0}; " & elementType &
          " *items = foo_sequence_owned(sizeof(*items), count, count); if (!items) return (" &
          typePrinter(declaration.ret) &
          "){\"OutOfMemory\", {0}}; " & copying & " return (" &
          typePrinter(declaration.ret) & "){0, (" & sliceType &
          "){items, count}}; }")
      continue

    if provider == "table":
      modules.incl("hashmap")
      let returnType = if declaration.ret.kind == TypeKind.Failable:
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
      else: raise newException(ValueError, "Unknown table operation '" & operation & "'")
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
      elif provider == "arch" and operation in ["tally", "combine"] and
          typ.kind == TypeKind.Slice:
        arguments.add("(FOOText){(const uint8_t *)p" & $index & ".data, p" & $index & ".len}")
      elif provider in ["arch", "binary", "memory", "crypto", "checksum"] and typ.kind == TypeKind.Slice:
        arguments.add("(FOOText){p" & $index & ".data, p" & $index & ".len}")
      else:
        arguments.add("p" & $index)
    let call = "foo_" & provider & "_" & operation & "(" & arguments.join(", ") & ")"
    let locked = provider in ["list", "memory", "stream"] and not
      (provider == "memory" and operation in ["transfer", "clear", "compare", "identical"])
    let leave = if locked: "foo_leave();" else: ""
    var body: string
    if declaration.ret.kind == TypeKind.Failable:
      let value = if declaration.ret.elem.kind == TypeKind.Slice:
          let pointer = if declaration.ret.elem.constant:
              "result.text.data"
            else:
              "(" & typePrinter(declaration.ret.elem.elem) & " *)result.text.data"
          "(" & typePrinter(declaration.ret.elem) & "){" & pointer & ", result.text.len}"
        elif declaration.ret.elem.kind == TypeKind.Ptr:
          "(" & typePrinter(declaration.ret.elem) & ")result.pointer"
        else:
          "result." & member(declaration.ret.elem)
      body = "FOOResult result = " & call & "; " & leave & " return (" &
        typePrinter(declaration.ret) & "){ result.error, " & value & " };"
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
  if not hosted:
    result.code = aliases & "\n" & defines.join("\n") & "\n" &
      archSource & "\n" & wrappers.join("\n")
    return
  let serviceCode = if "service" in modules:
    "#include \"service.h\"\nstatic const char *foo_service_error(int code) { static const char *names[] = {NULL, \"OutOfMemory\", \"InvalidInput\", \"IoFailure\", \"Closed\", \"MissingValue\", \"SystemFailure\", \"Bounds\"}; return code >= 0 && code < 8 ? names[code] : \"SystemFailure\"; }\n"
    else: ""
  let header = runtimeSource
    .replace("#include \"arch.h\"", archSource)
    .replace("#include \"json.h\"", jsonSource)
    .replace("#include \"http.h\"", httpSource)
    .replace("#include \"storage.h\"", storageSource)
    .replace("#include \"stream.h\"", streamSource)
  result.code = aliases & "\n" & defines.join("\n") & "\n" &
    (if "codec" in modules: "#include <errno.h>\n" else: "") &
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
