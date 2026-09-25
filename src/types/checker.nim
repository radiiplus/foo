import std/[options, sequtils, sets, strutils, tables]
import ../ast/node as ast
import ../diag/[code, engine, span]
import ../sema/bindings
import ./[coerce, env, escape, exhaust]
import ./type as semantic

type Checker* = ref object
  diag: Engine
  environment: Environment
  typeDefs: Table[string, semantic.Type]
  aliases: Table[string, ast.Alias]
  functions: Table[string, ast.Function]
  checked: HashSet[pointer]
  checking: HashSet[pointer]
  defining: HashSet[string]
  resultType: semantic.Type
  returns: seq[semantic.Type]
  loops: int
  leaving: int
  unsafeDepth: int
  propagates: bool
  scope: Environment
  parameters: Table[string, semantic.Type]
  requirements: seq[tuple[subject: string, trait: string]]
  allocators: seq[semantic.Type]
  types*: Table[pointer, semantic.Type]

proc primitive(name: string; width = 0): semantic.Type =
  semantic.Type(kind: "primitive", name: name, width: width)
proc unknown(): semantic.Type = semantic.Type(kind: "unknown")
proc nodeKey(node: ast.Node): pointer = cast[pointer](node)

proc newChecker*(diag: Engine): Checker =
  result = Checker(diag: diag, environment: newEnvironment(),
    typeDefs: initTable[string, semantic.Type](),
    aliases: initTable[string, ast.Alias](),
    functions: initTable[string, ast.Function](),
    checked: initHashSet[pointer](), checking: initHashSet[pointer](),
    defining: initHashSet[string](),
    resultType: unknown(), parameters: initTable[string, semantic.Type](),
    types: initTable[pointer, semantic.Type]())
  for name in ["integer", "unsigned", "decimal", "boolean", "byte",
      "character", "text", "nothing"]:
    result.typeDefs[name] = primitive(name)
  result.typeDefs["Error"] = primitive("Error")
  result.typeDefs["Allocator"] = semantic.Type(kind: "opaque", name: "Allocator")

proc annotation(checker: Checker; node: ast.`Type`): semantic.Type
proc infer(checker: Checker; node: ast.Expression; environment: Environment;
    expected: semantic.Type = nil): semantic.Type
proc statement(checker: Checker; node: ast.Statement; environment: Environment)

proc remember(checker: Checker; node: ast.Node; value: semantic.Type): semantic.Type =
  if node != nil: checker.types[nodeKey(node)] = value
  value

proc defaultType(checker: Checker; value: semantic.Type; at: Span): semantic.Type =
  if value != nil and value.kind == "literal":
    let target = primitive("integer")
    if not canCoerce(value, target).ok:
      checker.diag.emit(Code.TypeMismatch, at,
        "Integer literal is outside the default range; give it a wider expected type")
    target
  else: value

proc accepts(checker: Checker; value: semantic.Type; trait: string): bool =
  if value == nil: return false
  if value.kind == "named":
    for requirement in checker.requirements:
      if requirement.subject == value.name and
          (requirement.trait == trait or
            (trait == "Equatable" and requirement.trait in ["Hash", "Ord"])):
        return true
  if satisfies(value, trait): return true
  if value.kind in ["record", "choice"]:
    let base = value.name.split('[')[0]
    if not checker.aliases.hasKey(base): return false
    let alias = checker.aliases[base]
    var derives = false
    if alias.derives != nil:
      for derived in alias.derives.traits:
        if derived.text == trait: derives = true
    if not derives: return false
    if value.kind == "record":
      for field in value.fields.values:
        if not checker.accepts(field, trait): return false
    else:
      for variant in value.variants.values:
        if variant != nil and not checker.accepts(variant, trait): return false
    return true
  value.kind in ["optional", "sequence"] and checker.accepts(value.elem, trait)

proc packed(value: semantic.Type): bool =
  if value.kind == "primitive":
    return value.name in ["integer", "unsigned", "boolean", "byte"]
  value.kind == "record" and value.layout == "packed"

proc compatible(value: semantic.Type; allowVoid: bool): bool =
  if value == nil: return false
  if value.kind == "primitive":
    if value.name == "nothing": return allowVoid
    return value.name in ["integer", "unsigned", "decimal", "boolean", "byte", "character"]
  if value.kind == "pointer": return true
  if value.kind == "function":
    if value.abi != "c" or not compatible(value.ret, true): return false
    for parameter in value.params:
      if not compatible(parameter, false): return false
    return true
  value.kind in ["record", "union"] and value.layout == "c"

proc attributes(checker: Checker; member: ast.Member) =
  for attribute in member.attributes:
    if attribute != "volatile":
      checker.diag.emit(Code.Invalid, member.span,
        "unknown field attribute '#[" & attribute & "]'")
  if "volatile" in member.attributes and member.type.tag != "pointer":
    checker.diag.emit(Code.Invalid, member.span,
      "#[volatile] fields must be pointers")
    checker.diag.suggestion("Declare the register as a pointer type")

proc defineAlias(checker: Checker; alias: ast.Alias) =
  if alias.name.text in checker.defining: return
  if checker.typeDefs.hasKey(alias.name.text) and
      checker.typeDefs[alias.name.text].kind != "named": return
  checker.defining.incl(alias.name.text)
  let shell = if alias.body != nil and alias.body.tag == "record":
    semantic.Type(kind: "record", name: alias.name.text,
      fields: initOrderedTable[string, semantic.Type]())
    else: semantic.Type(kind: "named", name: alias.name.text)
  checker.typeDefs[alias.name.text] = shell
  if alias.body == nil: return
  let savedParameters = checker.parameters
  checker.parameters = initTable[string, semantic.Type]()
  for parameter in alias.typeParams:
    checker.parameters[parameter.name.text] = semantic.Type(kind: "named", name: parameter.name.text)
  case alias.body.tag
  of "record":
    var fields = initOrderedTable[string, semantic.Type]()
    for field in ast.Record(alias.body).fields:
      checker.attributes(field)
      fields[field.name.text] = checker.annotation(field.type)
    checker.typeDefs[alias.name.text] = semantic.Type(kind: "record",
      name: alias.name.text, fields: fields, layout: ast.Record(alias.body).layout)
    if ast.Record(alias.body).layout == "packed":
      for field in ast.Record(alias.body).fields:
        if not packed(fields[field.name.text]):
          checker.diag.emit(Code.Invalid, field.type.span,
            "packed field '" & field.name.text &
            "' must be an integer, boolean, or packed value")
          checker.diag.suggestion("Store pointers and managed values outside the packed record")
    elif ast.Record(alias.body).layout == "c":
      for field in ast.Record(alias.body).fields:
        if not compatible(fields[field.name.text], false):
          checker.diag.emit(Code.Invalid, field.type.span,
            "field '" & field.name.text & "' is not valid in a c record")
  of "union":
    var fields = initOrderedTable[string, semantic.Type]()
    for field in ast.Union(alias.body).fields:
      checker.attributes(field)
      let fieldType = checker.annotation(field.type)
      fields[field.name.text] = fieldType
      if not compatible(fieldType, false):
        checker.diag.emit(Code.Invalid, field.type.span,
          "field '" & field.name.text & "' is not valid in a c union")
    checker.typeDefs[alias.name.text] = semantic.Type(kind: "union",
      name: alias.name.text, fields: fields, layout: "c")
  of "choice":
    var variants = initOrderedTable[string, semantic.Type]()
    for variant in ast.Choice(alias.body).variants:
      variants[variant.name.text] = if variant.payload == nil: nil else: checker.annotation(variant.payload)
    checker.typeDefs[alias.name.text] = semantic.Type(kind: "choice",
      name: alias.name.text, variants: variants)
  of "opaque": checker.typeDefs[alias.name.text] = semantic.Type(kind: "opaque", name: alias.name.text)
  else: checker.typeDefs[alias.name.text] = checker.annotation(alias.body)
  shell[] = checker.typeDefs[alias.name.text][]
  checker.typeDefs[alias.name.text] = shell
  checker.parameters = savedParameters
  checker.defining.excl(alias.name.text)

proc annotation(checker: Checker; node: ast.`Type`): semantic.Type =
  if node == nil: return unknown()
  case node.tag
  of "primitive":
    let value = ast.Primitive(node)
    var width = 0
    if value.width.len > 0:
      try: width = parseInt(value.width)
      except ValueError: checker.diag.emit(Code.Invalid, node.span, "Invalid numeric width")
    if width > 0 and ((value.name == "decimal" and width notin [32, 64]) or
        (value.name != "decimal" and (width < 1 or width > 128))):
      checker.diag.emit(Code.Invalid, node.span, "Invalid numeric width")
    result = primitive(value.name, width)
  of "array": result = semantic.Type(kind: "array", elem: checker.annotation(ast.Array(node).elem))
  of "sequence":
    let sequence = ast.Sequence(node)
    result = semantic.Type(kind: "sequence", elem: checker.annotation(sequence.elem), constant: sequence.constant)
  of "optional": result = semantic.Type(kind: "optional", elem: checker.annotation(ast.Optional(node).elem))
  of "error": result = semantic.Type(kind: "error", elem: checker.annotation(ast.Error(node).elem))
  of "pointer": result = semantic.Type(kind: "pointer", elem: checker.annotation(ast.Pointer(node).elem))
  of "vector":
    let vector = ast.Vector(node)
    var length = 0
    try: length = parseInt(vector.length)
    except ValueError: discard
    if length <= 0: checker.diag.emit(Code.Invalid, node.span, "vector lane count must be a positive compile-time integer")
    let element = checker.annotation(vector.elem)
    if not (element.kind == "pointer" or
        (element.kind == "primitive" and element.name in
          ["integer", "unsigned", "decimal", "boolean", "byte"])):
      checker.diag.emit(Code.Invalid, vector.elem.span,
        "invalid vector element type " & typeToString(element))
    result = semantic.Type(kind: "vector", length: length, elem: element)
  of "function-type":
    let functionType = ast.FunctionType(node)
    var params: seq[semantic.Type]
    for parameter in functionType.params: params.add(checker.annotation(parameter))
    result = semantic.Type(kind: "function", params: params,
      ret: checker.annotation(functionType.ret), abi: functionType.abi)
  of "generic-inst":
    let generic = ast.GenericInst(node)
    if checker.aliases.hasKey(generic.name.text): checker.defineAlias(checker.aliases[generic.name.text])
    if checker.typeDefs.hasKey(generic.name.text):
      let alias = if checker.aliases.hasKey(generic.name.text):
        checker.aliases[generic.name.text] else: nil
      let parameters = if alias != nil: alias.typeParams else: @[]
      if generic.args.len != parameters.len:
        checker.diag.emit(Code.Invalid, node.span,
          "Expected " & $parameters.len & " type arguments")
      var replacements = initTable[string, semantic.Type]()
      for index, argument in generic.args:
        if index < parameters.len:
          replacements[parameters[index].name.text] = checker.annotation(argument)
      if alias != nil:
        for constraint in alias.constraints:
          let subject = constraint.subject.text
          if not replacements.hasKey(subject) or
              not checker.accepts(replacements[subject], constraint.trait.text):
            checker.diag.emit(Code.TypeMismatch, node.span,
              "Type argument does not satisfy " & constraint.trait.text)
        for parameter in alias.typeParams:
          if parameter.bound != nil and replacements.hasKey(parameter.name.text) and
              not checker.accepts(replacements[parameter.name.text], parameter.bound.text):
            checker.diag.emit(Code.TypeMismatch, node.span,
              "Type argument does not satisfy " & parameter.bound.text)
      result = substitute(checker.typeDefs[generic.name.text], replacements)
      if result.kind in ["record", "choice"]:
        for parameter in parameters:
          if replacements.hasKey(parameter.name.text):
            result.arguments.add(replacements[parameter.name.text])
        result.name = generic.name.text & "[" &
          result.arguments.mapIt(typeToString(it)).join(", ") & "]"
    else:
      checker.diag.emit(Code.Missing, generic.name.span, "undefined type '" & generic.name.text & "'")
      result = unknown()
  of "named":
    let name = ast.Named(node).name
    if checker.parameters.hasKey(name.text): result = checker.parameters[name.text]
    elif checker.aliases.hasKey(name.text):
      checker.defineAlias(checker.aliases[name.text])
      result = checker.typeDefs[name.text]
    elif checker.typeDefs.hasKey(name.text): result = checker.typeDefs[name.text]
    else:
      checker.diag.emit(Code.Missing, name.span, "undefined type '" & name.text & "'")
      checker.diag.suggestion("Check if '" & name.text & "' is defined or imported")
      result = unknown()
  else: result = unknown()
  discard checker.remember(node, result)

proc signature(checker: Checker; node: ast.Node): semantic.Type =
  var params: seq[semantic.Type]
  var returnType: semantic.Type
  var abi = ""
  var generics: seq[string]
  var constraints: seq[tuple[subject: string, trait: string]]
  let savedParameters = checker.parameters
  checker.parameters = initTable[string, semantic.Type]()
  if node.tag == "function":
    let function = ast.Function(node)
    for parameter in function.typeParams:
      generics.add(parameter.name.text)
      checker.parameters[parameter.name.text] = semantic.Type(kind: "named", name: parameter.name.text)
      if parameter.bound != nil: constraints.add((parameter.name.text, parameter.bound.text))
    for parameter in function.params: params.add(checker.annotation(parameter.type))
    returnType = if function.returnType == nil: unknown() else: checker.annotation(function.returnType)
    abi = function.abi
    for constraint in function.constraints: constraints.add((constraint.subject.text, constraint.trait.text))
  else:
    let function = ast.ExternFunction(node)
    for parameter in function.typeParams:
      generics.add(parameter.name.text)
      checker.parameters[parameter.name.text] = semantic.Type(kind: "named", name: parameter.name.text)
      if parameter.bound != nil: constraints.add((parameter.name.text, parameter.bound.text))
    for parameter in function.params: params.add(checker.annotation(parameter.type))
    returnType = checker.annotation(function.returnType)
    abi = function.abi
    for constraint in function.constraints: constraints.add((constraint.subject.text, constraint.trait.text))
  checker.parameters = savedParameters
  semantic.Type(kind: "function", params: params, ret: returnType,
    abi: abi, generics: generics, constraints: constraints,
    borrows: if node.tag == "extern-function" and
      ((abi == "runtime.memory" and ast.ExternFunction(node).symbol in
        ["transfer", "clear", "compare"]) or abi in ["runtime", "runtime.hashmap"]):
        toSeq(0 ..< params.len) else: @[])

proc boolean(checker: Checker; value: semantic.Type; at: Span) =
  if value == nil or value.kind != "primitive" or value.name != "boolean":
    checker.diag.emit(Code.Invalid, at, "expected boolean, found " & typeToString(value))
    checker.diag.suggestion("Use a boolean expression or comparison")

proc terminates(body: ast.Block): bool =
  if body == nil: return false
  for node in body.stmts:
    if node.tag in ["give", "unreachable-statement"]: return true
    if node.tag == "unsafe" and terminates(ast.Unsafe(node).body): return true
    if node.tag == "when":
      let branch = ast.`When`(node)
      if branch.else != nil and terminates(branch.then):
        if branch.else.tag == "block" and terminates(ast.Block(branch.else)): return true
    if node.tag == "match":
      let match = ast.Match(node)
      if match.cases.len > 0 and match.cases.allIt(terminates(it.body)): return true
  false

proc pattern(checker: Checker; pattern: ast.Pattern; value: semantic.Type;
    environment: Environment) =
  if pattern.tag == "variant-pattern":
    let variant = ast.VariantPattern(pattern)
    if value.kind != "choice":
      checker.diag.emit(Code.Invalid, pattern.span,
        "payload patterns require a choice type")
      return
    if not value.variants.hasKey(variant.name.text):
      checker.diag.emit(Code.VariantNotFound, variant.name.span,
        "choice " & value.name & " has no variant '" & variant.name.text & "'")
    else:
      let payload = value.variants[variant.name.text]
      if variant.binding != nil and payload == nil:
        checker.diag.emit(Code.Invalid, variant.binding.span,
          "variant '" & variant.name.text & "' has no payload to bind")
      elif variant.binding != nil:
        environment.define(variant.binding.text, payload)
  elif pattern.tag == "name" and ast.Name(pattern).text != "_":
    let name = ast.Name(pattern).text
    if value.kind == "choice":
      if not value.variants.hasKey(name):
        checker.diag.emit(Code.VariantNotFound, pattern.span,
          "choice " & value.name & " has no variant '" & name & "'")
    else:
      let found = environment.lookup(name)
      if found == nil or not canCoerce(found, value).ok:
        checker.diag.emit(Code.TypeMismatch, pattern.span,
          "A named pattern must be a compatible constant or variant")
  elif pattern.tag != "wildcard":
    discard checker.infer(pattern, environment, value)

proc machine(checker: Checker; expression: ast.Machine; environment: Environment): semantic.Type =
  let integer = primitive("integer", 64)
  let unsigned = primitive("unsigned", 64)
  if expression.operation == "system":
    discard checker.infer(expression.value, environment, integer)
    if expression.args.len > 6:
      checker.diag.emit(Code.Invalid, expression.span, "A system call accepts at most six machine-word arguments")
    for argument in expression.args:
      let valueType = checker.infer(argument, environment)
      if valueType.kind notin ["pointer", "literal"] and
          not (valueType.kind == "primitive" and valueType.name in ["integer", "unsigned"]):
        checker.diag.emit(Code.Invalid, argument.span, "System call arguments must be integers or pointers")
    return integer
  if expression.operation == "register":
    discard checker.infer(expression.value, environment, unsigned)
    return primitive("nothing")

  let target = expression.target
  let targetType = checker.infer(target, environment)
  if target.tag != "name" or not environment.mutable(ast.Name(target).text):
    checker.diag.emit(Code.Invalid, target.span, "Machine updates need a dynamic binding")
  if expression.operation == "align":
    if targetType.kind notin ["pointer", "sequence"]:
      checker.diag.emit(Code.Invalid, target.span, "Alignment requires a pointer or sequence")
    if targetType.kind == "sequence" and targetType.constant:
      checker.diag.emit(Code.Invalid, target.span, "Alignment requires a dynamic sequence view")
    discard checker.infer(expression.value, environment, unsigned)
    var valid = expression.value != nil and expression.value.tag == "integer"
    if valid:
      try:
        let alignment = parseBiggestUInt(ast.Integer(expression.value).value.replace("_", ""))
        valid = alignment > 0 and (alignment and (alignment - 1)) == 0
      except ValueError: valid = false
    if not valid: checker.diag.emit(Code.Invalid, expression.span, "Alignment must be a positive constant power of two")
  else:
    let width = if targetType.width > 0: targetType.width else: 64
    if targetType.kind != "primitive" or targetType.name notin ["integer", "unsigned"] or width notin [8, 16, 32, 64]:
      checker.diag.emit(Code.Invalid, target.span, "Atomic and bit updates require a fixed-width integer")
    discard checker.infer(expression.value, environment, if expression.operation == "atomic": targetType else: unsigned)
  primitive("nothing")

proc vector(checker: Checker; name: string; args: seq[ast.Expression];
    environment: Environment; expected: semantic.Type; at: Span): semantic.Type =
  if name == "splat":
    if expected == nil or expected.kind != "vector":
      checker.diag.emit(Code.Invalid, at, "splat needs an expected vector type")
      checker.diag.suggestion("Declare the result as, for example, 'of type vector[4, decimal 32]'")
      return unknown()
    if args.len != 1: checker.diag.emit(Code.Invalid, at, "splat expects exactly one scalar value")
    if args.len > 0: discard checker.infer(args[0], environment, expected.elem)
    return expected
  if name == "shuffle":
    if args.len < 3:
      checker.diag.emit(Code.Invalid, at, "shuffle expects two vectors followed by lane indices")
      return unknown()
    let left = checker.infer(args[0], environment)
    let right = checker.infer(args[1], environment, left)
    if left.kind != "vector" or right.kind != "vector" or not canCoerce(right, left).ok:
      checker.diag.emit(Code.Invalid, at, "shuffle inputs must be equal vector types")
      return unknown()
    for index in args[2 .. ^1]:
      if index.tag != "integer":
        checker.diag.emit(Code.Invalid, index.span, "shuffle lane indices must be integer literals")
      else:
        try:
          let lane = parseInt(ast.Integer(index).value)
          if lane < 0 or lane >= left.length * 2:
            checker.diag.emit(Code.Invalid, index.span, "shuffle lane is outside the input vectors")
        except ValueError:
          checker.diag.emit(Code.Invalid, index.span, "shuffle lane indices must be integer literals")
    return semantic.Type(kind: "vector", length: args.len - 2, elem: left.elem)
  if name == "select":
    if args.len != 3:
      checker.diag.emit(Code.Invalid, at, "select expects a boolean mask and two vectors")
      return unknown()
    let mask = checker.infer(args[0], environment)
    let yes = checker.infer(args[1], environment)
    let no = checker.infer(args[2], environment, yes)
    if mask.kind != "vector" or mask.elem.kind != "primitive" or
        mask.elem.name != "boolean" or yes.kind != "vector" or
        no.kind != "vector" or mask.length != yes.length or not canCoerce(no, yes).ok:
      checker.diag.emit(Code.Invalid, at,
        "select requires vector[lanes, boolean] and two equal vectors")
      return unknown()
    return yes
  if args.len != 2:
    checker.diag.emit(Code.Invalid, at, "reduce expects a vector and a text operation")
    return unknown()
  let input = checker.infer(args[0], environment)
  if input.kind != "vector" or args[1].tag != "text" or
      ast.Text(args[1]).value notin ["add", "multiply", "minimum", "maximum", "and", "or", "xor"]:
    checker.diag.emit(Code.Invalid, at,
      "reduce operation must be add, multiply, minimum, maximum, and, or, or xor")
    return unknown()
  input.elem

proc infer(checker: Checker; node: ast.Expression; environment: Environment;
    expected: semantic.Type = nil): semantic.Type =
  if node == nil: return unknown()
  case node.tag
  of "integer":
    let literal = semantic.Type(kind: "literal", value: ast.Integer(node).value)
    result = if expected != nil and canCoerce(literal, expected).ok: expected else: literal
  of "decimal": result = if expected != nil and expected.kind == "primitive" and expected.name == "decimal": expected else: primitive("decimal", 64)
  of "text": result = primitive("text")
  of "character": result = primitive("character")
  of "true", "false": result = primitive("boolean")
  of "nothing": result = primitive("nothing")
  of "uninitialized": result = if expected == nil: unknown() else: expected
  of "unreachable": result = primitive("never")
  of "newline": result = primitive("text")
  of "quantity": result = primitive("integer", 64)
  of "broken": result = unknown()
  of "name":
    let name = ast.Name(node).text
    result = environment.lookup(name)
    if result == nil:
      checker.diag.emit(Code.Missing, node.span, "undefined symbol '" & name & "'")
      checker.diag.suggestion("Check if '" & name & "' is defined or imported")
      result = unknown()
    elif not environment.initialized(name):
      checker.diag.emit(Code.Invalid, node.span, "Read of uninitialized '" & name & "'")
  of "call":
    let call = ast.Call(node)
    if call.callee.tag == "name" and ast.Name(call.callee).text == "fail" and
        environment.lookup("fail") == nil and call.args.len == 1:
      discard checker.infer(call.args[0], environment, checker.typeDefs["Error"])
      result = semantic.Type(kind: "error", elem: primitive("never"))
    elif call.callee.tag == "name" and ast.Name(call.callee).text in
        ["splat", "shuffle", "select", "reduce"]:
      result = checker.vector(ast.Name(call.callee).text, call.args, environment, expected, node.span)
    elif call.callee.tag == "name" and
        checker.typeDefs.hasKey(ast.Name(call.callee).text):
      result = if call.types.len > 0:
        checker.annotation(ast.GenericInst(tag: "generic-inst", span: node.span,
          name: ast.Name(call.callee), args: call.types))
        else: checker.typeDefs[ast.Name(call.callee).text]
      if result.kind != "record":
        checker.diag.emit(Code.Invalid, call.callee.span,
          "cannot construct non-record type")
        return checker.remember(node, unknown())
      var fields: seq[semantic.Type]
      for value in result.fields.values: fields.add(value)
      if call.args.len != fields.len:
        checker.diag.emit(Code.Invalid, node.span, "Expected " & $fields.len & " field values")
      for index, argument in call.args:
        discard checker.infer(argument, environment, if index < fields.len: fields[index] else: nil)
    else:
      var callee = checker.infer(call.callee, environment)
      if callee.kind != "function":
        checker.diag.emit(Code.Invalid, call.callee.span, "cannot call non-function type")
        checker.diag.note(call.callee.span, "found type: " & typeToString(callee))
        result = unknown()
      else:
        if callee.generics.len > 0:
          var replacements = initTable[string, semantic.Type]()
          if call.types.len > 0:
            if call.types.len != callee.generics.len:
              checker.diag.emit(Code.Invalid, node.span, "Expected " & $callee.generics.len & " type arguments")
            for index, argument in call.types:
              if index < callee.generics.len:
                replacements[callee.generics[index]] = checker.annotation(argument)
          proc bindGeneric(pattern, actual: semantic.Type) =
            if pattern == nil or actual == nil: return
            if pattern.kind == "named" and pattern.name in callee.generics:
              let value = checker.defaultType(actual, node.span)
              if replacements.hasKey(pattern.name):
                if not canCoerce(value, replacements[pattern.name]).ok:
                  checker.diag.emit(Code.TypeMismatch, node.span, "Conflicting types for '" & pattern.name & "'")
              else: replacements[pattern.name] = value
            elif pattern.kind == actual.kind and pattern.elem != nil and actual.elem != nil:
              bindGeneric(pattern.elem, actual.elem)
            elif pattern.kind == "function" and actual.kind == "function":
              for index, parameter in pattern.params:
                if index < actual.params.len: bindGeneric(parameter, actual.params[index])
              bindGeneric(pattern.ret, actual.ret)
          for index, argument in call.args:
            if index < callee.params.len: bindGeneric(callee.params[index], checker.infer(argument, environment))
          for name in callee.generics:
            if not replacements.hasKey(name):
              checker.diag.emit(Code.TypeMismatch, node.span, "Cannot infer '" & name & "'; supply its type argument")
          for requirement in callee.constraints:
            if replacements.hasKey(requirement.subject) and
                not checker.accepts(replacements[requirement.subject], requirement.trait):
              checker.diag.emit(Code.TypeMismatch, node.span,
                typeToString(replacements[requirement.subject]) & " does not satisfy " & requirement.trait)
          callee = substitute(callee, replacements)
        elif call.types.len > 0:
          checker.diag.emit(Code.Invalid, node.span, "This function has no type parameters")
        if call.args.len != callee.params.len:
          checker.diag.emit(Code.Invalid, node.span, "expected " & $callee.params.len &
            " arguments, got " & $call.args.len)
        for index, argument in call.args:
          let parameter = if index < callee.params.len: callee.params[index] else: nil
          discard checker.infer(argument, environment, parameter)
        result = callee.ret
  of "unary":
    let unary = ast.Unary(node)
    let operand = checker.infer(unary.operand, environment)
    if unary.op == "not":
      if operand.kind == "vector" and operand.elem.kind == "primitive" and
          operand.elem.name == "boolean": result = operand
      else: checker.boolean(operand, unary.operand.span); result = primitive("boolean")
    elif unary.op == "try":
      if checker.leaving > 0:
        checker.diag.emit(Code.Invalid, node.span,
          "after cannot propagate an error; handle it with fallback")
      if not checker.propagates:
        checker.diag.emit(Code.Invalid, node.span,
          "This function needs a fallible return type to use try")
      if operand.kind == "error": result = operand.elem
      else: checker.diag.emit(Code.Invalid, node.span, "try needs a fallible value"); result = unknown()
    else: result = operand
  of "binary":
    let binary = ast.Binary(node)
    let comparison = binary.op in ["equals", "does not equal", "is greater than", "is less than", "is at least", "is at most"]
    let context = if expected != nil and expected.kind in ["error", "optional"]:
      expected.elem else: expected
    let left = checker.infer(binary.left, environment,
      if comparison or binary.op == "catch" or
        (context != nil and context.kind == "literal"): nil else: context)
    if binary.op == "catch":
      if left.kind != "error": checker.diag.emit(Code.Invalid, binary.left.span, "catch needs a fallible value"); result = unknown()
      else: discard checker.infer(binary.right, environment, left.elem); result = left.elem
    else:
      let right = checker.infer(binary.right, environment,
        if left.kind in ["literal", "vector"]: nil else: left)
      if left.kind == "literal" and right.kind == "literal": result = if comparison: primitive("boolean") else: checker.defaultType(left, node.span)
      elif not canCoerce(right, left).ok and not canCoerce(left, right).ok:
        checker.diag.emit(Code.TypeMismatch, binary.right.span,
          "operands have different types: " & typeToString(left) & " and " & typeToString(right))
        result = if comparison: primitive("boolean") else: left
      elif comparison:
        if left.kind == "named" and not checker.accepts(left,
            if binary.op in ["equals", "does not equal"]: "Equatable" else: "Ord"):
          checker.diag.emit(Code.TypeMismatch, node.span,
            "The operator needs a constraint on " & left.name)
        result = if left.kind == "vector":
          semantic.Type(kind: "vector", length: left.length,
            elem: primitive("boolean")) else: primitive("boolean")
      elif binary.op in ["and", "or"]:
        checker.boolean(left, binary.left.span); checker.boolean(right, binary.right.span); result = primitive("boolean")
      else:
        if left.kind == "vector":
          if left.elem.kind != "primitive" or left.elem.name notin
              ["integer", "unsigned", "decimal", "byte"]:
            checker.diag.emit(Code.Invalid, node.span,
              "operator '" & binary.op & "' requires a numeric vector")
        elif not (left.kind == "literal" or
            (left.kind == "primitive" and
              (left.name in ["integer", "unsigned", "decimal", "byte"] or
                (binary.op == "plus" and left.name == "text")))):
          checker.diag.emit(Code.TypeMismatch, node.span,
            "Operator '" & binary.op & "' needs numeric values")
        result = left
  of "group": result = checker.infer(ast.Group(node).expr, environment, expected)
  of "field":
    let field = ast.Field(node)
    if field.object.tag == "name" and ast.Name(field.object).text == "Error" and
        checker.typeDefs.hasKey("Error") and environment.lookup("Error") == nil:
      result = checker.typeDefs["Error"]
      discard checker.remember(node, result)
      return result
    if field.object.tag == "name" and checker.typeDefs.hasKey(ast.Name(field.object).text):
      let choice = checker.typeDefs[ast.Name(field.object).text]
      if choice.kind == "choice" and choice.variants.hasKey(field.field.text):
        let payload = choice.variants[field.field.text]
        result = if payload == nil: choice else:
          semantic.Type(kind: "function", params: @[payload], ret: choice)
        discard checker.remember(node, result)
        return result
    let owner = checker.infer(field.object, environment)
    if owner.kind == "record" and owner.fields.hasKey(field.field.text): result = owner.fields[field.field.text]
    else:
      checker.diag.emit(Code.Missing, field.field.span, "record has no field '" & field.field.text & "'")
      result = unknown()
  of "index":
    let index = ast.Index(node)
    let owner = checker.infer(index.object, environment)
    let offset = checker.infer(index.index, environment)
    if offset.kind != "literal" and not (offset.kind == "primitive" and offset.name in ["integer", "unsigned"]):
      checker.diag.emit(Code.NotIndexable, index.index.span, "An index must be an integer")
    if owner.kind in ["array", "sequence", "vector"]: result = owner.elem
    elif owner.kind == "primitive" and owner.name == "text": result = primitive("byte")
    else: checker.diag.emit(Code.Invalid, index.object.span, "cannot index non-sequence type"); result = unknown()
  of "error-chain":
    discard checker.infer(ast.ErrorChain(node).context, environment)
    result = checker.infer(ast.ErrorChain(node).expr, environment, expected)
  of "reflect":
    discard checker.annotation(ast.Reflect(node).type)
    result = semantic.Type(kind: "record", name: "__description",
      fields: initOrderedTable[string, semantic.Type]())
    result.fields["name"] = primitive("text"); result.fields["kind"] = primitive("text")
    result.fields["size"] = primitive("unsigned", 64); result.fields["alignment"] = primitive("unsigned", 64)
  of "embed": result = if ast.Embed(node).type != nil: checker.annotation(ast.Embed(node).type) elif expected != nil: expected else: semantic.Type(kind: "sequence", elem: primitive("byte"))
  of "allocation":
    let allocation = ast.Allocation(node)
    let size = checker.infer(allocation.size, environment)
    if size.kind != "literal" and not (size.kind == "primitive" and size.name in ["integer", "unsigned"]):
      checker.diag.emit(Code.TypeMismatch, allocation.size.span, "Allocation size must be an integer")
    if size.kind == "literal":
      try:
        if parseBiggestInt(size.value.replace("_", "")) < 0:
          checker.diag.emit(Code.Invalid, allocation.size.span,
            "Allocation size cannot be negative")
      except ValueError: discard
    if allocation.owner != nil:
      let owner = checker.infer(allocation.owner, environment)
      var valid = canCoerce(owner, checker.typeDefs["Allocator"]).ok
      for allocator in checker.allocators:
        if canCoerce(owner, allocator).ok: valid = true
      if not valid:
        checker.diag.emit(Code.TypeMismatch, allocation.owner.span,
          "Allocation needs an Allocator value or an allocator obtained from memory.system() or memory.arena()")
    result = semantic.Type(kind: "error", elem: semantic.Type(kind: "sequence", elem: primitive("byte")))
  of "machine": result = checker.machine(ast.Machine(node), environment)
  else: result = unknown()
  if expected != nil and expected.kind != "unknown" and result.kind != "unknown" and not canCoerce(result, expected).ok:
    checker.diag.emit(Code.TypeMismatch, node.span,
      "type mismatch: expected " & typeToString(expected) & ", found " & typeToString(result))
  discard checker.remember(node, result)

proc checkBlock(checker: Checker; body: ast.Block; environment: Environment) =
  if body == nil: return
  for node in body.stmts: checker.statement(node, environment)

proc statement(checker: Checker; node: ast.Statement; environment: Environment) =
  case node.tag
  of "constant", "mutable":
    let declared = if node.tag == "constant": ast.Constant(node).type else: ast.Mutable(node).type
    let value = if node.tag == "constant": ast.Constant(node).value else: ast.Mutable(node).value
    let name = if node.tag == "constant": ast.Constant(node).name.text else: ast.Mutable(node).name.text
    let declaredType = if declared == nil: nil else: checker.annotation(declared)
    let valueType = checker.infer(value, environment, declaredType)
    let finalType = if declaredType != nil: declaredType elif node.tag == "constant" and valueType.kind == "literal": valueType else: checker.defaultType(valueType, value.span)
    environment.define(name, finalType, node.tag == "mutable", value.tag != "uninitialized")
    discard checker.remember(node, finalType)
  of "function":
    let function = ast.Function(node)
    if nodeKey(node) in checker.checked: return
    if nodeKey(node) in checker.checking:
      if function.returnType == nil: checker.diag.emit(Code.TypeMismatch, node.span, "A recursive function needs an explicit result type")
      return
    checker.checking.incl(nodeKey(node))
    var functionType = environment.lookup(function.name.text)
    if functionType == nil or functionType.kind != "function": functionType = checker.signature(node)
    let savedParameters = checker.parameters
    let savedRequirements = checker.requirements
    checker.parameters = initTable[string, semantic.Type]()
    for name in functionType.generics:
      checker.parameters[name] = semantic.Type(kind: "named", name: name)
    checker.requirements = functionType.constraints
    var seen = initHashSet[string]()
    for requirement in checker.requirements:
      let key = requirement.subject & ":" & requirement.trait
      if not checker.parameters.hasKey(requirement.subject):
        checker.diag.emit(Code.Invalid, node.span,
          "Constraint subject '" & requirement.subject & "' is not a type parameter")
      if requirement.trait notin ["Equatable", "Hash", "Ord", "Allocator"]:
        checker.diag.emit(Code.Invalid, node.span,
          "Unknown constraint '" & requirement.trait & "'")
      if key in seen:
        checker.diag.emit(Code.Duplicate, node.span,
          "Repeated constraint '" & key & "'")
      seen.incl(key)
    if function.abi.len > 0 and function.abi notin ["c", "runtime"]:
      checker.diag.emit(Code.Invalid, node.span,
        "unsupported function ABI '" & function.abi &
        "'; expected 'c' or 'runtime'")
    environment.define(function.name.text, functionType)
    let local = environment.child
    for index, parameter in function.params: local.define(parameter.name.text, functionType.params[index])
    let savedResult = checker.resultType
    let savedReturns = checker.returns
    let savedLoops = checker.loops
    let savedPropagates = checker.propagates
    checker.resultType = functionType.ret; checker.returns = @[]; checker.loops = 0
    checker.propagates = function.returnType == nil or
      functionType.ret.kind == "error" or function.name.text == "start"
    checker.checkBlock(function.body, local)
    checkEscape(function.body, local, checker.diag, checker.types)
    if functionType.ret.kind == "unknown":
      functionType.ret = if checker.returns.len > 0: checker.defaultType(checker.returns[0], node.span) else: primitive("nothing")
      for returned in checker.returns:
        if not canCoerce(returned, functionType.ret).ok:
          checker.diag.emit(Code.TypeMismatch, node.span,
            "Function returns incompatible types; declare its result type")
    let inner = if functionType.ret.kind == "error": functionType.ret.elem else: functionType.ret
    if not (inner.kind == "primitive" and inner.name == "nothing") and not terminates(function.body):
      checker.diag.emit(Code.TypeMismatch, node.span, "This function must give a result on every path")
    discard checker.remember(node, functionType)
    environment.define(function.name.text, functionType)
    checker.resultType = savedResult; checker.returns = savedReturns
    checker.loops = savedLoops; checker.propagates = savedPropagates
    checker.parameters = savedParameters
    checker.requirements = savedRequirements
    checker.checking.excl(nodeKey(node)); checker.checked.incl(nodeKey(node))
  of "extern-function":
    let external = ast.ExternFunction(node)
    let functionType = checker.signature(node)
    discard checker.remember(node, functionType)
    if external.abi != "c" and external.abi != "runtime" and
        (not external.abi.startsWith("runtime.") or
          binding(provider(external.abi)).isNone):
      checker.diag.emit(Code.Invalid, node.span,
        "unsupported function source '" & provider(external.abi) &
        "'; expected 'c' or a supported library name")
    if external.abi != "runtime" and not external.abi.startsWith("runtime."):
      for index, parameter in functionType.params:
        if not compatible(parameter, false):
          checker.diag.emit(Code.Invalid, external.params[index].type.span,
            "parameter '" & external.params[index].name.text &
            "' is not safe to pass by value to extern \"" &
            provider(external.abi) & "\"")
      if not compatible(functionType.ret, true):
        checker.diag.emit(Code.Invalid, external.returnType.span,
          "return type " & typeToString(functionType.ret) &
          " is not safe for extern \"" & provider(external.abi) & "\"")
  of "give":
    if checker.leaving > 0:
      checker.diag.emit(Code.Invalid, node.span,
        "A cleanup block cannot return from its function")
    let value = ast.Give(node).value
    let found = if value == nil: primitive("nothing") else: checker.infer(value, environment, if checker.resultType.kind == "unknown": nil else: checker.resultType)
    if value == nil and checker.resultType.kind != "unknown" and
        not canCoerce(found, checker.resultType).ok:
      checker.diag.emit(Code.TypeMismatch, node.span,
        "Expected " & typeToString(checker.resultType) & ", found nothing")
    checker.returns.add(found)
  of "when":
    let branch = ast.`When`(node)
    checker.boolean(checker.infer(branch.cond, environment), branch.cond.span)
    let yes = environment.child; let no = environment.child
    checker.checkBlock(branch.then, yes)
    if branch.else != nil:
      if branch.else.tag == "when": checker.statement(branch.else, no)
      else: checker.checkBlock(ast.Block(branch.else), no)
    environment.join(@[yes, no])
  of "while":
    let loop = ast.`While`(node)
    checker.boolean(checker.infer(loop.cond, environment), loop.cond.span)
    inc checker.loops; checker.checkBlock(loop.body, environment.child); dec checker.loops
  of "repeat":
    discard checker.infer(ast.Repeat(node).target, environment)
    discard checker.infer(ast.Repeat(node).limit, environment)
    inc checker.loops; checker.checkBlock(ast.Repeat(node).body, environment.child); dec checker.loops
  of "for":
    let loop = ast.`For`(node)
    let iterable = checker.infer(loop.iter, environment)
    let local = environment.child
    if iterable.kind in ["array", "sequence", "vector"]: local.define(loop.bind.text, iterable.elem)
    else: checker.diag.emit(Code.Invalid, loop.iter.span, "expected sequence type, found " & typeToString(iterable)); local.define(loop.bind.text, unknown())
    inc checker.loops; checker.checkBlock(loop.body, local); dec checker.loops
  of "match":
    let matchNode = ast.Match(node)
    let scrutinee = checker.infer(matchNode.scrutinee, environment)
    checkExhaustiveness(scrutinee, matchNode.cases,
      matchNode.scrutinee.span, checker.diag)
    for arm in matchNode.cases:
      let local = environment.child
      checker.pattern(arm.pattern, scrutinee, local)
      if arm.guard != nil:
        checker.boolean(checker.infer(arm.guard, local), arm.guard.span)
      checker.checkBlock(arm.body, local)
  of "assignment":
    let assignment = ast.Assignment(node)
    var targetType = unknown()
    if assignment.target.tag == "name":
      let name = ast.Name(assignment.target).text
      let found = environment.lookup(name)
      if found != nil: targetType = found
      if not environment.mutable(name): checker.diag.emit(Code.Invalid, assignment.target.span, "Assignment needs a dynamic binding")
      discard checker.infer(assignment.value, environment, targetType)
      environment.initialize(name)
    else:
      targetType = checker.infer(assignment.target, environment)
      if assignment.target.tag == "index":
        let owner = checker.types.getOrDefault(
          nodeKey(ast.Index(assignment.target).object))
        if owner != nil and ((owner.kind == "sequence" and owner.constant) or
            (owner.kind == "primitive" and owner.name == "text")):
          checker.diag.emit(Code.Invalid, assignment.target.span,
            "This sequence is read-only")
      elif assignment.target.tag == "field":
        var root = ast.Field(assignment.target).object
        while root.tag == "field": root = ast.Field(root).object
        if root.tag == "name" and not environment.mutable(ast.Name(root).text):
          checker.diag.emit(Code.Invalid, assignment.target.span,
            "Changing a field needs a dynamic binding")
      elif assignment.target.tag notin ["index", "field"]:
        checker.diag.emit(Code.Invalid, assignment.target.span,
          "This destination cannot be assigned")
      discard checker.infer(assignment.value, environment, targetType)
  of "break", "continue":
    if checker.loops == 0 or checker.leaving > 0:
      checker.diag.emit(Code.Invalid, node.span,
        "Loop control needs an enclosing loop and cannot leave cleanup")
  of "try":
    if checker.leaving > 0:
      checker.diag.emit(Code.Invalid, node.span,
        "after cannot propagate an error; handle it with fallback")
    let value = checker.infer(ast.`Try`(node).expr, environment)
    if value.kind != "error": checker.diag.emit(Code.Invalid, node.span, "try needs a fallible value")
    if not checker.propagates:
      checker.diag.emit(Code.Invalid, node.span,
        "This function needs a fallible return type to use try")
  of "unsafe": inc checker.unsafeDepth; checker.checkBlock(ast.Unsafe(node).body, environment.child); dec checker.unsafeDepth
  of "defer":
    let deferred = ast.`Defer`(node)
    if checker.leaving > 0:
      checker.diag.emit(Code.Invalid, node.span,
        "A cleanup block cannot register another cleanup")
    inc checker.leaving
    if deferred.body.tag == "block":
      checker.checkBlock(ast.Block(deferred.body), environment.child)
    else:
      let value = checker.infer(deferred.body, environment)
      if value.kind != "unknown" and not
          (value.kind == "primitive" and value.name == "nothing"):
        checker.diag.emit(Code.Invalid, node.span,
          "after needs a cleanup returning nothing; handle errors with fallback")
    dec checker.leaving
  of "test":
    let savedPropagates = checker.propagates
    let savedResult = checker.resultType
    let savedReturns = checker.returns
    checker.propagates = true
    checker.resultType = semantic.Type(kind: "error",
      elem: primitive("nothing"))
    checker.returns = @[]
    checker.checkBlock(ast.TestBlock(node).body, environment.child)
    checker.propagates = savedPropagates
    checker.resultType = savedResult
    checker.returns = savedReturns
  of "eval": checker.checkBlock(ast.EvalBlock(node).body, environment)
  of "action":
    let action = ast.Action(node)
    var actionType: semantic.Type
    if action.value != nil: actionType = checker.infer(action.value, environment)
    else:
      let call = ast.Call(tag: "call", span: node.span, callee: action.name, args: action.args)
      actionType = checker.infer(call, environment)
    if actionType != nil and actionType.kind == "error":
      checker.diag.emit(Code.Invalid, node.span,
        "This call can fail. Use try or fallback to handle its error")
  of "machine": discard checker.infer(node, environment)
  of "advance":
    let target = ast.AdvanceStatement(node).target
    if not environment.mutable(target.text):
      checker.diag.emit(Code.Invalid, node.span,
        "Advance needs a dynamic binding")
    discard checker.infer(target, environment)
  else: discard

proc check*(checker: Checker; program: ast.Program) =
  for unit in program.units:
    for node in unit.body.stmts:
      if node.tag == "alias": checker.aliases[ast.Alias(node).name.text] = ast.Alias(node)
      elif node.tag == "function": checker.functions[ast.Function(node).name.text] = ast.Function(node)
    for alias in checker.aliases.values: checker.defineAlias(alias)
    let moduleEnv = checker.environment.child
    checker.scope = moduleEnv
    for node in unit.body.stmts:
      if node.tag in ["function", "extern-function"]:
        let name = if node.tag == "function": ast.Function(node).name.text else: ast.ExternFunction(node).name.text
        let functionType = checker.signature(node)
        moduleEnv.define(name, functionType)
        if node.tag == "extern-function":
          let external = ast.ExternFunction(node)
          let externalSymbol = if external.symbol.len > 0:
            external.symbol else: external.name.text
          if external.abi == "runtime.memory" and
              externalSymbol in ["system", "arena"]:
            checker.allocators.add(if functionType.ret.kind == "error":
              functionType.ret.elem else: functionType.ret)
      elif node.tag == "alias" and ast.Alias(node).body.tag == "choice":
        let choice = checker.typeDefs[ast.Alias(node).name.text]
        for name, payload in choice.variants:
          moduleEnv.define(name, if payload == nil: choice else: semantic.Type(kind: "function", params: @[payload], ret: choice))
    for node in unit.body.stmts:
      if node.tag in ["constant", "mutable"]:
        let declared = if node.tag == "constant":
          ast.Constant(node).type else: ast.Mutable(node).type
        let expression = if node.tag == "constant":
          ast.Constant(node).value else: ast.Mutable(node).value
        let name = if node.tag == "constant":
          ast.Constant(node).name.text else: ast.Mutable(node).name.text
        let valueType = if declared != nil: checker.annotation(declared)
          elif expression.tag in ["integer", "decimal", "text", "true",
              "false", "nothing"]: checker.infer(expression, moduleEnv)
          else: unknown()
        moduleEnv.define(name, valueType)
    for node in unit.body.stmts: checker.statement(node, moduleEnv)
