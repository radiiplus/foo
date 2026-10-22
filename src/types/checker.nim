import std/[options, sequtils, sets, strutils, tables]
import ../ast/node as ast
import ../diag/[code, engine, span]
import ../sema/bindings
import ./[coerce, env, escape, exhaust]
import ./type as semantic

type Checker* = ref object
  diag: Engine
  environment: Environment
  definitions: Table[string, semantic.Type]
  aliases: Table[string, ast.Alias]
  functions: Table[string, seq[ast.Function]]
  closures: HashSet[string]
  checked: HashSet[pointer]
  checking: HashSet[pointer]
  defining: HashSet[string]
  returning: semantic.Type
  returns: seq[semantic.Type]
  loops: int
  leaving: int
  propagates: bool
  scope: Environment
  parameters: Table[string, semantic.Type]
  requirements: seq[tuple[subject: string, trait: string]]
  allocators: seq[semantic.Type]
  types*: Table[pointer, semantic.Type]

proc primitive(name: string; width = 0): semantic.Type =
  semantic.Type(kind: "primitive", name: name, width: width)
proc unknown(): semantic.Type = semantic.Type(kind: "unknown")
proc key(node: ast.Node): pointer = cast[pointer](node)

proc checker*(diag: Engine): Checker =
  result = Checker(diag: diag, environment: environment(),
    definitions: initTable[string, semantic.Type](),
    aliases: initTable[string, ast.Alias](),
    functions: initTable[string, seq[ast.Function]](),
    checked: initHashSet[pointer](), checking: initHashSet[pointer](),
    defining: initHashSet[string](), closures: initHashSet[string](),
    returning: unknown(), parameters: initTable[string, semantic.Type](),
    types: initTable[pointer, semantic.Type]())
  for name in ["integer", "unsigned", "decimal", "boolean", "byte",
      "character", "text", "nothing"]:
    result.definitions[name] = primitive(name)
  result.definitions["Error"] = primitive("Error")
  result.definitions["allocator"] = semantic.Type(kind: "opaque", name: "allocator")

proc annotation(checker: Checker; node: ast.`Type`): semantic.Type
proc infer(checker: Checker; node: ast.Expression; environment: Environment;
    expected: semantic.Type = nil; preserve = false): semantic.Type
proc statement(checker: Checker; node: ast.Statement; environment: Environment)

proc remember(checker: Checker; node: ast.Node; value: semantic.Type): semantic.Type =
  if node != nil: checker.types[key(node)] = value
  value

proc defaulting(checker: Checker; value: semantic.Type; at: Span): semantic.Type =
  if value != nil and value.kind == "literal":
    let target = primitive("integer")
    if not coercion(value, target).ok:
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
        if derived.text == trait or
            (trait == "Equatable" and derived.text in ["Hash", "Ord"]):
          derives = true
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

proc compatible(value: semantic.Type; void: bool): bool =
  if value == nil: return false
  if value.kind == "primitive":
    if value.name == "nothing": return void
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
        "unknown field access option '" & attribute & "'")
  if "volatile" in member.attributes and member.type.tag != "pointer":
    checker.diag.emit(Code.Invalid, member.span,
      "Fields with exact access must be pointers")
    checker.diag.suggestion("Declare the register as a pointer type")

proc alias(checker: Checker; alias: ast.Alias) =
  if alias.name.text in checker.defining: return
  if checker.definitions.hasKey(alias.name.text) and
      checker.definitions[alias.name.text].kind != "named": return
  checker.defining.incl(alias.name.text)
  var boundary = 0
  for attribute in alias.attributes:
    if attribute.startsWith("align("):
      var valid = attribute.endsWith(")") and boundary == 0
      if valid:
        try:
          boundary = parseInt(attribute[6 ..< attribute.len - 1])
          valid = boundary > 0 and boundary <= 4096 and
            (boundary and (boundary - 1)) == 0
        except ValueError: valid = false
      if not valid or alias.body == nil or alias.body.tag != "record" or
          ast.Record(alias.body).layout != "c" or
          ast.Record(alias.body).fields.len == 0:
        checker.diag.emit(Code.Invalid, alias.span,
          "aligned to requires one power-of-two byte value up to 4096 on a nonempty c record")
  let shell = if alias.body != nil and alias.body.tag == "record":
    semantic.Type(kind: "record", name: alias.name.text,
      fields: initOrderedTable[string, semantic.Type]())
    else: semantic.Type(kind: "named", name: alias.name.text)
  checker.definitions[alias.name.text] = shell
  if alias.body == nil: return
  let inputs = checker.parameters
  checker.parameters = initTable[string, semantic.Type]()
  for parameter in alias.generics:
    checker.parameters[parameter.name.text] = semantic.Type(kind: "named", name: parameter.name.text)
  case alias.body.tag
  of "record":
    var fields = initOrderedTable[string, semantic.Type]()
    for field in ast.Record(alias.body).fields:
      checker.attributes(field)
      fields[field.name.text] = checker.annotation(field.type)
    checker.definitions[alias.name.text] = semantic.Type(kind: "record",
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
      let member = checker.annotation(field.type)
      fields[field.name.text] = member
      if not compatible(member, false):
        checker.diag.emit(Code.Invalid, field.type.span,
          "field '" & field.name.text & "' is not valid in a c union")
    checker.definitions[alias.name.text] = semantic.Type(kind: "union",
      name: alias.name.text, fields: fields, layout: "c")
  of "choice":
    var variants = initOrderedTable[string, semantic.Type]()
    for variant in ast.Choice(alias.body).variants:
      variants[variant.name.text] = if variant.payload == nil: nil else: checker.annotation(variant.payload)
    checker.definitions[alias.name.text] = semantic.Type(kind: "choice",
      name: alias.name.text, variants: variants)
  of "opaque": checker.definitions[alias.name.text] = semantic.Type(kind: "opaque", name: alias.name.text)
  else: checker.definitions[alias.name.text] = checker.annotation(alias.body)
  shell[] = checker.definitions[alias.name.text][]
  checker.definitions[alias.name.text] = shell
  checker.parameters = inputs
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
        "invalid vector element type " & label(element))
    result = semantic.Type(kind: "vector", length: length, elem: element)
  of "function-type":
    let callable = ast.Signature(node)
    var params: seq[semantic.Type]
    for parameter in callable.params: params.add(checker.annotation(parameter))
    result = semantic.Type(kind: "function", params: params,
      ret: checker.annotation(callable.ret), abi: callable.abi)
  of "generic-inst":
    let generic = ast.Instantiation(node)
    if checker.aliases.hasKey(generic.name.text): checker.alias(checker.aliases[generic.name.text])
    if checker.definitions.hasKey(generic.name.text):
      let alias = if checker.aliases.hasKey(generic.name.text):
        checker.aliases[generic.name.text] else: nil
      let parameters = if alias != nil: alias.generics else: @[]
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
        for parameter in alias.generics:
          if parameter.bound != nil and replacements.hasKey(parameter.name.text) and
              not checker.accepts(replacements[parameter.name.text], parameter.bound.text):
            checker.diag.emit(Code.TypeMismatch, node.span,
              "Type argument does not satisfy " & parameter.bound.text)
      result = substitute(checker.definitions[generic.name.text], replacements)
      if result.kind in ["record", "choice"]:
        for parameter in parameters:
          if replacements.hasKey(parameter.name.text):
            result.arguments.add(replacements[parameter.name.text])
        result.name = generic.name.text & "[" &
          result.arguments.mapIt(label(it)).join(", ") & "]"
    else:
      checker.diag.emit(Code.Missing, generic.name.span, "undefined type '" & generic.name.text & "'")
      result = unknown()
  of "named":
    let name = ast.Named(node).name
    if checker.parameters.hasKey(name.text): result = checker.parameters[name.text]
    elif checker.aliases.hasKey(name.text):
      checker.alias(checker.aliases[name.text])
      result = checker.definitions[name.text]
    elif checker.definitions.hasKey(name.text): result = checker.definitions[name.text]
    else:
      checker.diag.emit(Code.Missing, name.span, "undefined type '" & name.text & "'")
      checker.diag.suggestion("Check if '" & name.text & "' is defined or imported")
      result = unknown()
  else: result = unknown()
  discard checker.remember(node, result)

proc constructor(checker: Checker; alias: ast.Alias; choice: semantic.Type;
    name: string): semantic.Type =
  let payload = choice.variants.getOrDefault(name)
  if alias.generics.len == 0:
    return if payload == nil: choice else:
      semantic.Type(kind: "function", params: @[payload], ret: choice)

  var replacements = initTable[string, semantic.Type]()
  var arguments: seq[semantic.Type]
  var generics: seq[string]
  var constraints: seq[tuple[subject: string, trait: string]]
  for parameter in alias.generics:
    let formal = semantic.Type(kind: "named", name: parameter.name.text)
    replacements[parameter.name.text] = formal
    arguments.add(formal)
    generics.add(parameter.name.text)
    if parameter.bound != nil:
      constraints.add((parameter.name.text, parameter.bound.text))
  for constraint in alias.constraints:
    constraints.add((constraint.subject.text, constraint.trait.text))

  let specialized = substitute(choice, replacements)
  specialized.arguments = arguments
  specialized.name = alias.name.text & "[" & generics.join(", ") & "]"
  let instantiation = specialized.variants.getOrDefault(name)
  semantic.Type(kind: "function",
    params: if instantiation == nil: @[] else: @[instantiation],
    ret: specialized, generics: generics, constraints: constraints)

proc signature(checker: Checker; node: ast.Node): semantic.Type =
  var params: seq[semantic.Type]
  var labels: seq[string]
  var defaults: seq[bool]
  var variadic = false
  var returns: semantic.Type
  var abi = ""
  var generics: seq[string]
  var borrows: seq[int]
  var releases: seq[int]
  var constraints: seq[tuple[subject: string, trait: string]]
  let inputs = checker.parameters
  checker.parameters = initTable[string, semantic.Type]()
  if node.tag == "function":
    let function = ast.Function(node)
    for parameter in function.generics:
      generics.add(parameter.name.text)
      checker.parameters[parameter.name.text] = semantic.Type(kind: "named", name: parameter.name.text)
      if parameter.bound != nil: constraints.add((parameter.name.text, parameter.bound.text))
    for parameter in function.params:
      let formal = checker.annotation(parameter.type)
      params.add(if parameter.variadic:
        semantic.Type(kind: "sequence", elem: formal, constant: true) else: formal)
      labels.add(parameter.name.text)
      defaults.add(parameter.default != nil)
      if parameter.variadic: variadic = true
    returns = if function.returns == nil: unknown() else: checker.annotation(function.returns)
    abi = function.abi
    for attribute in function.attributes:
      if attribute.startsWith("borrows(") and attribute.endsWith(")"):
        let parameter = attribute[8 ..< attribute.len - 1]
        let index = labels.find(parameter)
        if index < 0:
          checker.diag.emit(Code.Invalid, function.span,
            "Borrow relationship names an unknown parameter '" & parameter & "'")
        elif index in borrows:
          checker.diag.emit(Code.Invalid, function.span,
            "Borrow relationship repeats parameter '" & parameter & "'")
        else:
          borrows.add(index)
      elif attribute.startsWith("releases(") and attribute.endsWith(")"):
        let parameter = attribute[9 ..< attribute.len - 1]
        let index = labels.find(parameter)
        if index < 0:
          checker.diag.emit(Code.Invalid, function.span,
            "Release relationship names an unknown parameter '" & parameter & "'")
        elif index in releases:
          checker.diag.emit(Code.Invalid, function.span,
            "Release relationship repeats parameter '" & parameter & "'")
        else:
          releases.add(index)
    for constraint in function.constraints: constraints.add((constraint.subject.text, constraint.trait.text))
  else:
    let function = ast.External(node)
    for parameter in function.generics:
      generics.add(parameter.name.text)
      checker.parameters[parameter.name.text] = semantic.Type(kind: "named", name: parameter.name.text)
      if parameter.bound != nil: constraints.add((parameter.name.text, parameter.bound.text))
    for parameter in function.params:
      params.add(checker.annotation(parameter.type))
      labels.add(parameter.name.text)
      defaults.add(false)
    returns = checker.annotation(function.returns)
    abi = function.abi
    for constraint in function.constraints: constraints.add((constraint.subject.text, constraint.trait.text))
  checker.parameters = inputs
  semantic.Type(kind: "function", params: params, ret: returns,
    abi: abi, generics: generics, constraints: constraints,
    labels: labels, defaults: defaults, variadic: variadic,
    releases: releases,
    borrows: if node.tag == "function": borrows
    elif node.tag == "extern-function" and
      ((abi == "runtime.memory" and
        (if ast.External(node).symbol.len > 0:
          ast.External(node).symbol else: ast.External(node).name.text) in
        ["transfer", "clear", "compare", "identical", "aligned", "bytes", "view"]) or
        (abi == "runtime.arch" and
          (if ast.External(node).symbol.len > 0:
            ast.External(node).symbol else: ast.External(node).name.text) in
        ["prefetch", "stage"]) or
        (abi == "runtime.fs" and ast.External(node).name.text == "borrow") or
        (abi == "runtime.sequence" and ast.External(node).name.text == "view") or
        abi in ["runtime", "runtime.table"]):
        toSeq(0 ..< params.len) else: @[])

proc clone(node: ast.Expression;
    replacements: Table[string, ast.Expression]): ast.Expression =
  if node == nil: return nil
  case node.tag
  of "name":
    let value = ast.Name(node)
    if replacements.hasKey(value.text): return replacements[value.text]
    ast.Name(tag: "name", span: node.span, text: value.text,
      invoke: value.invoke, arguments: value.arguments)
  of "integer": ast.Integer(tag: "integer", span: node.span, value: ast.Integer(node).value,
    spelling: ast.Integer(node).spelling)
  of "decimal": ast.Decimal(tag: "decimal", span: node.span, value: ast.Decimal(node).value,
    spelling: ast.Decimal(node).spelling)
  of "text": ast.Text(tag: "text", span: node.span, value: ast.Text(node).value)
  of "character": ast.Character(tag: "character", span: node.span, value: ast.Character(node).value)
  of "true": ast.`True`(tag: "true", span: node.span)
  of "false": ast.`False`(tag: "false", span: node.span)
  of "nothing": ast.Nothing(tag: "nothing", span: node.span)
  of "null": ast.Null(tag: "null", span: node.span)
  of "newline": ast.Line(tag: "newline", span: node.span)
  of "group": ast.Group(tag: "group", span: node.span,
    expr: clone(ast.Group(node).expr, replacements))
  of "unary":
    let value = ast.Unary(node)
    ast.Unary(tag: "unary", span: node.span, op: value.op,
      operand: clone(value.operand, replacements))
  of "binary":
    let value = ast.Binary(node)
    ast.Binary(tag: "binary", span: node.span, op: value.op,
      left: clone(value.left, replacements),
      right: clone(value.right, replacements))
  of "call":
    let value = ast.Call(node)
    var arguments: seq[ast.Expression]
    for argument in value.args:
      arguments.add(clone(argument, replacements))
    ast.Call(tag: "call", span: node.span,
      callee: clone(value.callee, replacements), args: arguments,
      names: value.names, types: value.types)
  of "field":
    let value = ast.Field(node)
    ast.Field(tag: "field", span: node.span,
      `object`: clone(value.object, replacements), field: value.field)
  of "index":
    let value = ast.Index(node)
    ast.Index(tag: "index", span: node.span,
      `object`: clone(value.object, replacements),
      index: clone(value.index, replacements))
  of "sequence-value":
    var items: seq[ast.Expression]
    for item in ast.Values(node).items:
      items.add(clone(item, replacements))
    ast.Values(tag: "sequence-value", span: node.span, items: items)
  else: node

proc normalize(checker: Checker; call: ast.Call;
    declaration: ast.Function) =
  if declaration.params.len == 0:
    if call.names.anyIt(it.len > 0):
      checker.diag.emit(Code.Invalid, call.span, "This function has no named parameters")
    return
  var ordered = newSeq[ast.Expression](declaration.params.len)
  var supplied = newSeq[bool](declaration.params.len)
  var packed: seq[ast.Expression]
  var positional = 0
  let rest = if declaration.params[^1].variadic:
    declaration.params.high else: -1
  for index, argument in call.args:
    let label = if index < call.names.len: call.names[index] else: ""
    if label.len > 0:
      var found = -1
      for cursor, parameter in declaration.params:
        if parameter.name.text == label: found = cursor
      if found < 0:
        checker.diag.emit(Code.Invalid, argument.span,
          "unknown named argument '" & label & "'")
      elif found == rest:
        checker.diag.emit(Code.Invalid, argument.span,
          "variadic parameter '" & label & "' is supplied positionally")
      elif supplied[found]:
        checker.diag.emit(Code.Duplicate, argument.span,
          "argument '" & label & "' was supplied more than once")
      else:
        ordered[found] = argument
        supplied[found] = true
    elif rest >= 0 and positional >= rest:
      packed.add(argument)
    elif positional < declaration.params.len:
      ordered[positional] = argument
      supplied[positional] = true
      inc positional
    else:
      checker.diag.emit(Code.Invalid, argument.span, "too many arguments")
  var replacements = initTable[string, ast.Expression]()
  for index, parameter in declaration.params:
    if index == rest:
      ordered[index] = ast.Values(tag: "sequence-value", span: call.span,
        items: packed)
      supplied[index] = true
    elif not supplied[index] and parameter.default != nil:
      ordered[index] = clone(parameter.default, replacements)
      supplied[index] = true
    elif not supplied[index]:
      checker.diag.emit(Code.Invalid, call.span,
        "missing argument '" & parameter.name.text & "'")
      ordered[index] = ast.Broken(tag: "broken", span: call.span)
    replacements[parameter.name.text] = ordered[index]
  call.args = ordered
  call.names = newSeq[string](ordered.len)
  call.normalized = true

proc record(checker: Checker; call: ast.Call;
    record: semantic.Type) =
  var names: seq[string]
  for name in record.fields.keys: names.add(name)
  var ordered = newSeq[ast.Expression](names.len)
  var supplied = newSeq[bool](names.len)
  var positional = 0
  for index, argument in call.args:
    let label = if index < call.names.len: call.names[index] else: ""
    if label.len > 0:
      let found = names.find(label)
      if found < 0:
        checker.diag.emit(Code.Invalid, argument.span,
          "unknown record field '" & label & "'")
      elif supplied[found]:
        checker.diag.emit(Code.Duplicate, argument.span,
          "record field '" & label & "' was supplied more than once")
      else:
        ordered[found] = argument
        supplied[found] = true
    elif positional < names.len:
      ordered[positional] = argument
      supplied[positional] = true
      inc positional
    else:
      checker.diag.emit(Code.Invalid, argument.span,
        "too many record field values")
  for index, field in names:
    if not supplied[index]:
      checker.diag.emit(Code.Invalid, call.span,
        "missing record field '" & field & "'")
      ordered[index] = ast.Broken(tag: "broken", span: call.span)
  call.args = ordered
  call.names = newSeq[string](ordered.len)
  call.normalized = true

proc parameter(call: ast.Call; declaration: ast.Function;
    ordinal: int): int =
  let label = if ordinal < call.names.len: call.names[ordinal] else: ""
  if label.len > 0:
    for index, parameter in declaration.params:
      if parameter.name.text == label: return index
    return -1
  var position = 0
  for index in 0 .. ordinal:
    let current = if index < call.names.len: call.names[index] else: ""
    if current.len == 0:
      if index == ordinal: return min(position, declaration.params.high)
      inc position
  -1

proc matches(pattern, actual: semantic.Type; generics: seq[string]): bool =
  if pattern == nil or actual == nil: return false
  if pattern.kind == "named" and pattern.name in generics: return true
  if pattern.kind != actual.kind: return coercion(actual, pattern).ok
  case pattern.kind
  of "array", "sequence", "optional", "error", "pointer":
    actual.elem != nil and matches(pattern.elem, actual.elem, generics)
  of "named", "record", "choice", "union", "opaque":
    if pattern.arguments.len != actual.arguments.len: return false
    let left = pattern.name.find('[')
    let right = actual.name.find('[')
    if left >= 0 and right >= 0 and
        pattern.name[0 ..< left] != actual.name[0 ..< right]: return false
    if (left < 0 or right < 0) and pattern.name != actual.name: return false
    for index, expected in pattern.arguments:
      if not matches(expected, actual.arguments[index], generics): return false
    true
  of "vector":
    pattern.length == actual.length and actual.elem != nil and
      matches(pattern.elem, actual.elem, generics)
  of "function":
    if pattern.params.len != actual.params.len: return false
    for index, expected in pattern.params:
      if not matches(expected, actual.params[index], generics): return false
    matches(pattern.ret, actual.ret, generics)
  else: coercion(actual, pattern).ok

proc generic(pattern: semantic.Type; generics: seq[string]): bool =
  if pattern == nil: return false
  if pattern.kind == "named": return pattern.name in generics
  if pattern.elem != nil and generic(pattern.elem, generics): return true
  for argument in pattern.arguments:
    if generic(argument, generics): return true
  for parameter in pattern.params:
    if generic(parameter, generics): return true
  generic(pattern.ret, generics)

proc select(checker: Checker; call: ast.Call; environment: Environment):
    ast.Function =
  if call.normalized or call.callee.tag != "name": return nil
  let name = ast.Name(call.callee).text
  if not checker.functions.hasKey(name): return nil
  var actual: seq[semantic.Type]
  for argument in call.args:
    actual.add(checker.infer(argument, environment, preserve = true))
  var rank = low(int)
  var best: seq[ast.Function]
  for declaration in checker.functions[name]:
    let signature = checker.signature(declaration)
    var valid = true
    var score = 0
    var supplied = newSeq[bool](declaration.params.len)
    for index, candidate in actual:
      let cursor = parameter(call, declaration, index)
      if cursor < 0 or cursor >= declaration.params.len:
        valid = false
        break
      let parameter = declaration.params[cursor]
      let expected = if parameter.variadic: checker.annotation(parameter.type)
        else: signature.params[cursor]
      let flexible = generic(expected, signature.generics)
      if flexible and not matches(expected, candidate, signature.generics):
        valid = false
        break
      if not flexible and not coercion(candidate, expected).ok:
        valid = false
        break
      supplied[cursor] = true
      score += (if flexible: 1 elif equal(candidate, expected): 4 else: 2)
    if not valid: continue
    for index, parameter in declaration.params:
      if not supplied[index] and parameter.default == nil and not parameter.variadic:
        valid = false
      elif supplied[index]: score += 1
      elif parameter.default != nil: dec score
    if declaration.params.len > 0 and declaration.params[^1].variadic: dec score
    if not valid: continue
    if score > rank:
      rank = score
      best = @[declaration]
    elif score == rank:
      best.add(declaration)
  if best.len == 0:
    checker.diag.emit(Code.Invalid, call.span,
      "no overload of '" & name & "' accepts these arguments")
    return checker.functions[name][0]
  if best.len > 1:
    checker.diag.emit(Code.Invalid, call.span,
      "call to '" & name & "' is ambiguous between " & $best.len & " overloads")
  best[0]

proc boolean(checker: Checker; value: semantic.Type; at: Span) =
  if value == nil or value.kind != "primitive" or value.name != "boolean":
    checker.diag.emit(Code.Invalid, at, "expected boolean, found " & label(value))
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
    let variant = ast.Arm(pattern)
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
      if found == nil or not coercion(found, value).ok:
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
      let data = checker.infer(argument, environment)
      if data.kind notin ["pointer", "literal"] and
          not (data.kind == "primitive" and data.name in ["integer", "unsigned"]):
        checker.diag.emit(Code.Invalid, argument.span, "System call arguments must be integers or pointers")
    return integer
  if expression.operation == "register":
    discard checker.infer(expression.value, environment, unsigned)
    return primitive("nothing")

  let target = expression.target
  let destination = checker.infer(target, environment)
  if target.tag != "name" or not environment.mutable(ast.Name(target).text):
    checker.diag.emit(Code.Invalid, target.span, "Machine updates need a dynamic binding")
  if expression.operation == "align":
    if destination.kind notin ["pointer", "sequence"]:
      checker.diag.emit(Code.Invalid, target.span, "Alignment requires a pointer or sequence")
    if destination.kind == "sequence" and destination.constant:
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
    let width = if destination.width > 0: destination.width else: 64
    let permitted = if expression.operation == "atomic": width in [8, 16, 32, 64]
      else: width in 1..128
    if destination.kind != "primitive" or destination.name notin ["integer", "unsigned"] or not permitted:
      checker.diag.emit(Code.Invalid, target.span, "Atomic and bit updates require a fixed-width integer")
    discard checker.infer(expression.value, environment, if expression.operation == "atomic": destination else: unsigned)
  primitive("nothing")

proc bit(checker: Checker; call: ast.Call; environment: Environment;
    expected: semantic.Type): semantic.Type =
  let args = call.args
  if args.len notin [2, 3] or args[^1].tag != "text" or
      call.types.len > 0 or call.names.anyIt(it.len > 0):
    checker.diag.emit(Code.Invalid, call.span,
      "bit expects a value, an optional operand, and a literal operation")
    return unknown()
  let mode = ast.Text(args[^1]).value
  if mode notin ["shl", "lshr", "ashr", "and", "or", "xor",
      "not", "set", "clear", "toggle"] or (mode == "not") != (args.len == 2):
    checker.diag.emit(Code.Invalid, args[^1].span,
      "bit operation must be shl, lshr, ashr, and, or, xor, not, set, clear, or toggle with the matching arity")
    return unknown()
  let requested = if expected != nil and expected.kind == "primitive" and
      expected.name in ["integer", "unsigned"]: expected else: nil
  var left = checker.infer(args[0], environment, requested)
  left = checker.defaulting(left, args[0].span)
  let width = if left.width > 0: left.width else: 64
  if left.kind != "primitive" or left.name notin ["integer", "unsigned"] or
      width notin 1..128 or (mode == "ashr" and left.name != "integer"):
    checker.diag.emit(Code.TypeMismatch, args[0].span,
      "bit operation needs a 1..128-bit integer; ashr needs a signed integer")
    return unknown()
  if args.len == 3:
    let right = checker.infer(args[1], environment,
      if mode in ["and", "or", "xor"]: left else: nil)
    if mode in ["and", "or", "xor"]:
      if not coercion(right, left).ok:
        checker.diag.emit(Code.TypeMismatch, args[1].span,
          "bitwise operands must have compatible integer types")
    elif right.kind != "literal" and (right.kind != "primitive" or
        right.name notin ["integer", "unsigned"]):
      checker.diag.emit(Code.TypeMismatch, args[1].span,
        "shift and bit-update counts must be integers")
    elif right.kind == "literal":
      discard checker.defaulting(right, args[1].span)
  left

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
  if name == "permute":
    if args.len < 2:
      checker.diag.emit(Code.Invalid, at, "permute expects a vector followed by lane indices")
      return unknown()
    let input = checker.infer(args[0], environment)
    if input.kind != "vector":
      checker.diag.emit(Code.Invalid, at, "permute expects a vector")
      return unknown()
    for index in args[1 .. ^1]:
      if index.tag != "integer":
        checker.diag.emit(Code.Invalid, index.span, "permute lane indices must be integer literals")
      else:
        try:
          let lane = parseInt(ast.Integer(index).value)
          if lane < 0 or lane >= input.length:
            checker.diag.emit(Code.Invalid, index.span, "permute lane is outside the input vector")
        except ValueError:
          checker.diag.emit(Code.Invalid, index.span, "permute lane indices must be integer literals")
    return semantic.Type(kind: "vector", length: args.len - 1, elem: input.elem)
  if name in ["gather", "scatter"]:
    let count = if name == "gather": 2 else: 3
    if args.len != count:
      checker.diag.emit(Code.Invalid, at, name & " expects " & $count & " vectors")
      return unknown()
    let input = checker.infer(args[0], environment)
    let indices = checker.infer(args[1], environment)
    if input.kind != "vector" or indices.kind != "vector" or
        indices.elem.kind != "primitive" or
        indices.elem.name notin ["integer", "unsigned"]:
      checker.diag.emit(Code.Invalid, at,
        name & " requires a data vector and a vector of integer indices")
      return unknown()
    if name == "scatter":
      let values = checker.infer(args[2], environment)
      if values.kind != "vector" or values.length != indices.length or
          not coercion(values.elem, input.elem).ok:
        checker.diag.emit(Code.Invalid, at,
          "scatter values must match the index count and data element type")
      return input
    return semantic.Type(kind: "vector", length: indices.length, elem: input.elem)
  if name == "shuffle":
    if args.len < 3:
      checker.diag.emit(Code.Invalid, at, "shuffle expects two vectors followed by lane indices")
      return unknown()
    let left = checker.infer(args[0], environment)
    let right = checker.infer(args[1], environment, left)
    if left.kind != "vector" or right.kind != "vector" or not coercion(right, left).ok:
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
        no.kind != "vector" or mask.length != yes.length or not coercion(no, yes).ok:
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
  if input.elem.kind != "primitive" or
      input.elem.name notin ["integer", "unsigned", "decimal", "byte"] or
      (input.elem.name == "decimal" and
        ast.Text(args[1]).value in ["and", "or", "xor"]):
    checker.diag.emit(Code.Invalid, at,
      "reduce requires numeric lanes; and, or, and xor require integer lanes")
    return unknown()
  input.elem

proc infer(checker: Checker; node: ast.Expression; environment: Environment;
    expected: semantic.Type = nil; preserve = false): semantic.Type =
  if node == nil: return unknown()
  case node.tag
  of "integer":
    let literal = semantic.Type(kind: "literal", value: ast.Integer(node).value)
    result = if expected != nil and coercion(literal, expected).ok: expected else: literal
  of "decimal": result = if expected != nil and expected.kind == "primitive" and expected.name == "decimal": expected else: primitive("decimal", 64)
  of "text": result = primitive("text")
  of "character": result = primitive("character")
  of "true", "false": result = primitive("boolean")
  of "nothing": result = primitive("nothing")
  of "null":
    if expected != nil and expected.kind == "optional": result = expected
    else:
      checker.diag.emit(Code.TypeMismatch, node.span,
        "null needs an expected optional type")
      result = unknown()
  of "uninitialized": result = if expected == nil: unknown() else: expected
  of "unreachable": result = primitive("never")
  of "newline": result = primitive("text")
  of "broken": result = unknown()
  of "name":
    let item = ast.Name(node)
    let name = item.text
    item.invoke = false
    item.arguments = @[]
    result = environment.lookup(name)
    if result == nil:
      checker.diag.emit(Code.Missing, node.span, "undefined symbol '" & name & "'")
      checker.diag.suggestion("Check if '" & name & "' is defined or imported")
      result = unknown()
    elif not environment.initialized(name):
      checker.diag.emit(Code.Invalid, node.span, "Read of uninitialized '" & name & "'")
    elif result.kind == "function" and result.generics.len > 0 and
        result.params.len == 0 and result.ret != nil and
        result.ret.kind == "choice" and expected != nil and
        expected.kind == "choice" and
        result.ret.name.split('[')[0] == expected.name.split('[')[0] and
        result.ret.arguments.len == expected.arguments.len:
      var replacements = initTable[string, semantic.Type]()
      for index, argument in result.ret.arguments:
        if argument.kind == "named" and argument.name in result.generics:
          replacements[argument.name] = expected.arguments[index]
      if result.generics.allIt(replacements.hasKey(it)):
        result = substitute(result.ret, replacements)
        item.invoke = true
    elif result.kind == "function" and
        (result.params.len == 0 or
          (result.defaults.len == result.params.len and
            result.defaults.allIt(it)) or result.variadic) and
        not preserve and (expected == nil or expected.kind != "function"):
      if result.generics.len > 0:
        checker.diag.emit(Code.TypeMismatch, node.span,
          "Cannot infer generic type arguments for '" & name & "'")
        checker.diag.suggestion("Supply type arguments after the name, for example '" & name & "[Type]'")
        result = unknown()
      else:
        if checker.functions.hasKey(name):
          let implicit = ast.Call(tag: "call", span: node.span,
            callee: ast.Name(tag: "name", span: node.span, text: name),
            args: @[])
          let selected = checker.select(implicit, environment)
          if selected != nil:
            checker.normalize(implicit, selected)
            item.text = selected.name.text
            item.arguments = implicit.args
            result = checker.signature(selected)
        result = result.ret
        item.invoke = true
  of "call":
    let call = ast.Call(node)
    for argument in call.args:
      if argument.tag == "closure" or
          (argument.tag == "name" and ast.Name(argument).text in checker.closures):
        checker.diag.emit(Code.ScopeEscape, argument.span,
          "a scoped closure cannot be passed to another function")
        checker.diag.suggestion("Call the closure directly within its defining scope")
    let selected = checker.select(call, environment)
    if selected != nil:
      checker.normalize(call, selected)
      ast.Name(call.callee).text = selected.name.text
    if call.callee.tag == "name" and ast.Name(call.callee).text == "fail" and
        environment.lookup("fail") == nil and call.args.len == 1:
      discard checker.infer(call.args[0], environment, checker.definitions["Error"])
      result = semantic.Type(kind: "error", elem: primitive("never"))
    elif call.callee.tag == "name" and ast.Name(call.callee).text == "bit":
      result = checker.bit(call, environment, expected)
    elif call.callee.tag == "name" and ast.Name(call.callee).text == "lengthof":
      if call.args.len != 1:
        checker.diag.emit(Code.Invalid, node.span,
          "lengthof expects one text, sequence, array, or vector value")
        result = unknown()
      else:
        let input = checker.infer(call.args[0], environment)
        if input.kind notin ["array", "sequence", "vector"] and not
            (input.kind == "primitive" and input.name == "text"):
          checker.diag.emit(Code.TypeMismatch, call.args[0].span,
            "lengthof expects text, sequence, array, or vector")
        result = primitive("unsigned", 64)
    elif call.callee.tag == "name" and ast.Name(call.callee).text in
        ["splat", "shuffle", "permute", "gather", "scatter", "select", "reduce"]:
      result = checker.vector(ast.Name(call.callee).text, call.args, environment, expected, node.span)
    elif call.callee.tag == "name" and
        checker.definitions.hasKey(ast.Name(call.callee).text):
      result = if call.types.len > 0:
        checker.annotation(ast.Instantiation(tag: "generic-inst", span: node.span,
          name: ast.Name(call.callee), args: call.types))
        else: checker.definitions[ast.Name(call.callee).text]
      if result.kind != "record":
        checker.diag.emit(Code.Invalid, call.callee.span,
          "cannot construct non-record type")
        return checker.remember(node, unknown())
      checker.record(call, result)
      var fields: seq[semantic.Type]
      for value in result.fields.values: fields.add(value)
      if call.args.len != fields.len:
        checker.diag.emit(Code.Invalid, node.span, "Expected " & $fields.len & " field values")
      for index, argument in call.args:
        discard checker.infer(argument, environment, if index < fields.len: fields[index] else: nil)
    else:
      var callee = checker.infer(call.callee, environment,
        preserve = true)
      if callee.kind != "function":
        checker.diag.emit(Code.Invalid, call.callee.span, "cannot call non-function type")
        checker.diag.note(call.callee.span, "found type: " & label(callee))
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
          proc generic(pattern, actual: semantic.Type) =
            if pattern == nil or actual == nil: return
            if pattern.kind == "named" and pattern.name in callee.generics:
              if replacements.hasKey(pattern.name):
                if not coercion(actual, replacements[pattern.name]).ok:
                  checker.diag.emit(Code.TypeMismatch, node.span, "Conflicting types for '" & pattern.name & "'")
              else:
                replacements[pattern.name] = checker.defaulting(actual, node.span)
            elif pattern.kind == actual.kind and pattern.elem != nil and actual.elem != nil:
              generic(pattern.elem, actual.elem)
            elif pattern.kind == actual.kind and pattern.arguments.len > 0 and
                pattern.arguments.len == actual.arguments.len:
              for index, argument in pattern.arguments:
                generic(argument, actual.arguments[index])
            elif pattern.kind == "function" and actual.kind == "function":
              for index, parameter in pattern.params:
                if index < actual.params.len: generic(parameter, actual.params[index])
              generic(pattern.ret, actual.ret)
          for index, argument in call.args:
            if index < callee.params.len:
              generic(callee.params[index], checker.infer(argument,
                environment, preserve = true))
          for name in callee.generics:
            if not replacements.hasKey(name):
              checker.diag.emit(Code.TypeMismatch, node.span, "Cannot infer '" & name & "'; supply its type argument")
          for requirement in callee.constraints:
            if replacements.hasKey(requirement.subject) and
                not checker.accepts(replacements[requirement.subject], requirement.trait):
              checker.diag.emit(Code.TypeMismatch, node.span,
                label(replacements[requirement.subject]) & " does not satisfy " & requirement.trait)
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
  of "sequence-value":
    let sequence = ast.Values(node)
    let wanted = if expected != nil and expected.kind == "sequence":
      expected.elem else: nil
    var element = wanted
    for item in sequence.items:
      let current = checker.infer(item, environment, wanted)
      if element == nil: element = checker.defaulting(current, item.span)
      elif not coercion(current, element).ok:
        checker.diag.emit(Code.TypeMismatch, item.span,
          "sequence items must have one compatible type")
    if element == nil: element = unknown()
    result = semantic.Type(kind: "sequence", elem: element)
  of "closure":
    let closure = ast.Closure(node)
    var params: seq[semantic.Type]
    let local = environment.child
    for parameter in closure.params:
      let formal = checker.annotation(parameter.type)
      params.add(formal)
      local.define(parameter.name.text, formal)
    let response = checker.returning
    let previous = checker.returns
    let propagation = checker.propagates
    let output = if expected != nil and expected.kind == "function":
      expected.ret else: nil
    checker.returning = if closure.returns != nil:
      checker.annotation(closure.returns)
    elif output != nil: output
    else: unknown()
    checker.returns = @[]
    checker.propagates = checker.returning.kind == "error"
    for child in closure.body.stmts: checker.statement(child, local)
    if checker.returning.kind == "unknown":
      checker.returning = if checker.returns.len > 0:
        checker.defaulting(checker.returns[0], node.span)
      else: primitive("nothing")
    result = semantic.Type(kind: "function", params: params,
      ret: checker.returning)
    checker.returning = response
    checker.returns = previous
    checker.propagates = propagation
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
          "This function needs a failable return type to use try")
      if operand.kind == "error": result = operand.elem
      else: checker.diag.emit(Code.Invalid, node.span, "try needs a failable value"); result = unknown()
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
      if left.kind != "error": checker.diag.emit(Code.Invalid, binary.left.span, "catch needs a failable value"); result = unknown()
      else: discard checker.infer(binary.right, environment, left.elem); result = left.elem
    else:
      let right = checker.infer(binary.right, environment,
        if left.kind in ["literal", "vector"]: nil else: left)
      if left.kind == "literal" and right.kind == "literal": result = if comparison: primitive("boolean") else: checker.defaulting(left, node.span)
      elif not coercion(right, left).ok and not coercion(left, right).ok:
        checker.diag.emit(Code.TypeMismatch, binary.right.span,
          "operands have different types: " & label(left) & " and " & label(right))
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
    field.invoke = false
    if field.object.tag == "name" and ast.Name(field.object).text == "Error" and
        checker.definitions.hasKey("Error") and environment.lookup("Error") == nil:
      result = checker.definitions["Error"]
      discard checker.remember(node, result)
      return result
    if field.object.tag == "name" and checker.definitions.hasKey(ast.Name(field.object).text):
      let choice = checker.definitions[ast.Name(field.object).text]
      if choice.kind == "choice" and choice.variants.hasKey(field.field.text):
        let alias = checker.aliases.getOrDefault(ast.Name(field.object).text)
        result = if alias == nil:
          let payload = choice.variants[field.field.text]
          if payload == nil: choice else:
            semantic.Type(kind: "function", params: @[payload], ret: choice)
        else: checker.constructor(alias, choice, field.field.text)
        discard checker.remember(node, result)
        return result
    let owner = checker.infer(field.object, environment)
    if owner.kind == "record" and owner.fields.hasKey(field.field.text):
      result = owner.fields[field.field.text]
      if result.kind == "function" and result.params.len == 0 and
          not preserve and
          (expected == nil or expected.kind != "function"):
        result = result.ret
        field.invoke = true
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
      var valid = coercion(owner, checker.definitions["allocator"]).ok
      for allocator in checker.allocators:
        if coercion(owner, allocator).ok: valid = true
      if not valid:
        checker.diag.emit(Code.TypeMismatch, allocation.owner.span,
          "Allocation needs an Allocator value or an allocator obtained from memory.system or memory.arena")
    result = semantic.Type(kind: "error", elem: semantic.Type(kind: "sequence", elem: primitive("byte")))
  of "machine": result = checker.machine(ast.Machine(node), environment)
  else: result = unknown()
  if expected != nil and expected.kind != "unknown" and result.kind != "unknown" and not coercion(result, expected).ok:
    checker.diag.emit(Code.TypeMismatch, node.span,
      "type mismatch: expected " & label(expected) & ", found " & label(result))
  discard checker.remember(node, result)

proc inspect(checker: Checker; body: ast.Block; environment: Environment) =
  if body == nil: return
  for node in body.stmts: checker.statement(node, environment)

proc statement(checker: Checker; node: ast.Statement; environment: Environment) =
  case node.tag
  of "constant", "mutable":
    let declared = if node.tag == "constant": ast.Constant(node).type else: ast.Mutable(node).type
    let value = if node.tag == "constant": ast.Constant(node).value else: ast.Mutable(node).value
    let name = if node.tag == "constant": ast.Constant(node).name.text else: ast.Mutable(node).name.text
    if value.tag == "closure" and environment == checker.scope:
      checker.diag.emit(Code.Invalid, value.span,
        "a scoped closure must be declared inside a function")
    let shape = if declared == nil: nil else: checker.annotation(declared)
    let data = checker.infer(value, environment, shape)
    let final = if shape != nil: shape elif node.tag == "constant" and data.kind == "literal": data else: checker.defaulting(data, value.span)
    environment.define(name, final, node.tag == "mutable", value.tag != "uninitialized")
    if value.tag == "closure": checker.closures.incl(name)
    discard checker.remember(node, final)
  of "destructure":
    let destructure = ast.Destructure(node)
    let record = checker.annotation(destructure.record)
    if record.kind != "record":
      checker.diag.emit(Code.TypeMismatch, destructure.record.span,
        "record destructuring needs a record type")
      discard checker.infer(destructure.value, environment)
    else:
      discard checker.infer(destructure.value, environment, record)
      if destructure.fields.len != record.fields.len:
        checker.diag.emit(Code.Invalid, node.span,
          "record destructuring must bind every field exactly once")
      var seen = initHashSet[string]()
      for index, field in destructure.fields:
        if field.text in seen:
          checker.diag.emit(Code.Duplicate, field.span,
            "record field '" & field.text & "' was bound more than once")
        seen.incl(field.text)
        if not record.fields.hasKey(field.text):
          checker.diag.emit(Code.Missing, field.span,
            "record " & record.name & " has no field '" & field.text & "'")
        elif index < destructure.bindings.len:
          environment.define(destructure.bindings[index].text,
            record.fields[field.text])
      discard checker.remember(node, record)
  of "function":
    let function = ast.Function(node)
    if key(node) in checker.checked: return
    if key(node) in checker.checking:
      if function.returns == nil: checker.diag.emit(Code.TypeMismatch, node.span, "A recursive function needs an explicit result type")
      return
    checker.checking.incl(key(node))
    var callable = environment.lookup(function.name.text)
    if callable == nil or callable.kind != "function": callable = checker.signature(node)
    let inputs = checker.parameters
    let bounds = checker.requirements
    checker.parameters = initTable[string, semantic.Type]()
    for name in callable.generics:
      checker.parameters[name] = semantic.Type(kind: "named", name: name)
    checker.requirements = callable.constraints
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
    if function.abi.len > 0 and function.abi notin ["c", "runtime", "gpu"]:
      checker.diag.emit(Code.Invalid, node.span,
        "unsupported function ABI '" & function.abi &
        "'; expected 'c' or 'runtime'")
    environment.define(function.name.text, callable)
    let local = environment.child
    for index, parameter in function.params: local.define(parameter.name.text, callable.params[index])
    var optional = false
    for index, parameter in function.params:
      if parameter.variadic:
        if index != function.params.high:
          checker.diag.emit(Code.Invalid, parameter.span,
            "an each parameter must be the final parameter")
        if parameter.default != nil:
          checker.diag.emit(Code.Invalid, parameter.span,
            "an each parameter cannot also have a default")
      elif parameter.default != nil:
        optional = true
        discard checker.infer(parameter.default, local,
          checker.annotation(parameter.type))
      elif optional:
        checker.diag.emit(Code.Invalid, parameter.span,
          "required parameters must come before default parameters")
    let response = checker.returning
    let previous = checker.returns
    let saved = checker.loops
    let propagation = checker.propagates
    checker.returning = callable.ret; checker.returns = @[]; checker.loops = 0
    checker.propagates = function.returns == nil or
      callable.ret.kind == "error" or function.name.text == "start"
    if function.guard != nil:
      checker.boolean(checker.infer(function.guard, local), function.guard.span)
    checker.inspect(function.body, local)
    escape(function.body, local, checker.diag, checker.types,
      function.params.mapIt(it.name.text), callable.borrows)
    invalidate(function.body, local, checker.diag, checker.types,
      function.params.mapIt(it.name.text), callable.releases)
    if callable.ret.kind == "unknown":
      callable.ret = if checker.returns.len > 0: checker.defaulting(checker.returns[0], node.span) else: primitive("nothing")
      for returned in checker.returns:
        if not coercion(returned, callable.ret).ok:
          checker.diag.emit(Code.TypeMismatch, node.span,
            "Function returns incompatible types; declare its result type")
    let inner = if callable.ret.kind == "error": callable.ret.elem else: callable.ret
    if not (inner.kind == "primitive" and inner.name == "nothing") and not terminates(function.body):
      checker.diag.emit(Code.TypeMismatch, node.span, "This function must give a result on every path")
    discard checker.remember(node, callable)
    environment.define(function.name.text, callable)
    checker.returning = response; checker.returns = previous
    checker.loops = saved; checker.propagates = propagation
    checker.parameters = inputs
    checker.requirements = bounds
    checker.checking.excl(key(node)); checker.checked.incl(key(node))
  of "extern-function":
    let external = ast.External(node)
    let callable = checker.signature(node)
    discard checker.remember(node, callable)
    if external.abi != "c" and external.abi != "runtime" and
        (not external.abi.startsWith("runtime.") or
          binding(provider(external.abi)).isNone):
      checker.diag.emit(Code.Invalid, node.span,
        "unsupported function source '" & provider(external.abi) &
        "'; expected 'c' or a supported library name")
    if external.abi != "runtime" and not external.abi.startsWith("runtime."):
      for index, parameter in callable.params:
        if not compatible(parameter, false):
          checker.diag.emit(Code.Invalid, external.params[index].type.span,
            "parameter '" & external.params[index].name.text &
            "' is not safe to pass by value to extern \"" &
            provider(external.abi) & "\"")
      if not compatible(callable.ret, true):
        checker.diag.emit(Code.Invalid, external.returns.span,
          "return type " & label(callable.ret) &
          " is not safe for extern \"" & provider(external.abi) & "\"")
  of "give":
    if checker.leaving > 0:
      checker.diag.emit(Code.Invalid, node.span,
        "A cleanup block cannot return from its function")
    let value = ast.Give(node).value
    let found = if value == nil: primitive("nothing") else: checker.infer(value, environment, if checker.returning.kind == "unknown": nil else: checker.returning)
    if value != nil and found.kind == "function" and
        (value.tag == "closure" or
          (value.tag == "name" and ast.Name(value).text in checker.closures)):
      checker.diag.emit(Code.ScopeEscape, value.span,
        "a scoped closure cannot leave its defining function")
      checker.diag.suggestion("Call the closure within the scope that owns its captured values")
    if value == nil and checker.returning.kind != "unknown" and
        not coercion(found, checker.returning).ok:
      checker.diag.emit(Code.TypeMismatch, node.span,
        "Expected " & label(checker.returning) & ", found nothing")
    checker.returns.add(found)
  of "when":
    let branch = ast.`When`(node)
    checker.boolean(checker.infer(branch.cond, environment), branch.cond.span)
    let yes = environment.child; let no = environment.child
    checker.inspect(branch.then, yes)
    if branch.else != nil:
      if branch.else.tag == "when": checker.statement(branch.else, no)
      else: checker.inspect(ast.Block(branch.else), no)
    environment.join(@[yes, no])
  of "while":
    let loop = ast.`While`(node)
    checker.boolean(checker.infer(loop.cond, environment), loop.cond.span)
    inc checker.loops; checker.inspect(loop.body, environment.child); dec checker.loops
  of "for":
    let loop = ast.`For`(node)
    let iterable = checker.infer(loop.iter, environment)
    let local = environment.child
    if iterable.kind in ["array", "sequence", "vector"]: local.define(loop.bind.text, iterable.elem)
    elif iterable.kind == "primitive" and iterable.name == "text":
      local.define(loop.bind.text, primitive("byte"))
    else: checker.diag.emit(Code.Invalid, loop.iter.span, "expected sequence type, found " & label(iterable)); local.define(loop.bind.text, unknown())
    inc checker.loops; checker.inspect(loop.body, local); dec checker.loops
  of "match":
    let selection = ast.Match(node)
    let scrutinee = checker.infer(selection.scrutinee, environment)
    exhaust(scrutinee, selection.cases,
      selection.scrutinee.span, checker.diag)
    for arm in selection.cases:
      let local = environment.child
      checker.pattern(arm.pattern, scrutinee, local)
      if arm.guard != nil:
        checker.boolean(checker.infer(arm.guard, local), arm.guard.span)
      checker.inspect(arm.body, local)
  of "assignment":
    let assignment = ast.Assignment(node)
    var destination = unknown()
    if assignment.target.tag == "name":
      let name = ast.Name(assignment.target).text
      let found = environment.lookup(name)
      if found != nil: destination = found
      if not environment.mutable(name): checker.diag.emit(Code.Invalid, assignment.target.span, "Assignment needs a dynamic binding")
      discard checker.infer(assignment.value, environment, destination)
      environment.initialize(name)
    else:
      destination = checker.infer(assignment.target, environment)
      if assignment.target.tag == "index":
        let owner = checker.types.getOrDefault(
          key(ast.Index(assignment.target).object))
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
      discard checker.infer(assignment.value, environment, destination)
  of "break", "continue":
    if checker.loops == 0 or checker.leaving > 0:
      checker.diag.emit(Code.Invalid, node.span,
        "Loop control needs an enclosing loop and cannot leave cleanup")
  of "unsafe": checker.inspect(ast.Unsafe(node).body, environment.child)
  of "defer":
    let deferred = ast.`Defer`(node)
    if checker.leaving > 0:
      checker.diag.emit(Code.Invalid, node.span,
        "A cleanup block cannot register another cleanup")
    inc checker.leaving
    if deferred.body.tag == "block":
      checker.inspect(ast.Block(deferred.body), environment.child)
    else:
      let value = checker.infer(deferred.body, environment)
      if value.kind != "unknown" and not
          (value.kind == "primitive" and value.name == "nothing"):
        checker.diag.emit(Code.Invalid, node.span,
          "after needs a cleanup returning nothing; handle errors with fallback")
    dec checker.leaving
  of "test":
    let propagation = checker.propagates
    let response = checker.returning
    let previous = checker.returns
    checker.propagates = true
    checker.returning = semantic.Type(kind: "error",
      elem: primitive("nothing"))
    checker.returns = @[]
    checker.inspect(ast.Test(node).body, environment.child)
    invalidate(ast.Test(node).body, environment,
      checker.diag, checker.types)
    checker.propagates = propagation
    checker.returning = response
    checker.returns = previous
  of "eval": checker.inspect(ast.Evaluation(node).body, environment)
  of "action":
    let action = ast.Action(node)
    var representation: semantic.Type
    if action.value != nil: representation = checker.infer(action.value, environment)
    else:
      let call = ast.Call(tag: "call", span: node.span, callee: action.name, args: action.args)
      representation = checker.infer(call, environment)
    if representation != nil and representation.kind == "error":
      checker.diag.emit(Code.Invalid, node.span,
        "This call can fail. Use try or fallback to handle its error")
  of "machine": discard checker.infer(node, environment)
  else: discard

proc check*(checker: Checker; program: ast.Program) =
  for unit in program.units:
    for node in unit.body.stmts:
      if node.tag == "function":
        let function = ast.Function(node)
        function.dispatch = function.name.text
        checker.functions.mgetOrPut(function.dispatch, @[]).add(function)
  for original, overloads in checker.functions.mpairs:
    if overloads.len > 1:
      for index, function in overloads:
        function.name.text = original & "__overload_" & $(index + 1)
  for unit in program.units:
    for node in unit.body.stmts:
      if node.tag == "alias": checker.aliases[ast.Alias(node).name.text] = ast.Alias(node)
    for alias in checker.aliases.values: checker.alias(alias)
    let module = checker.environment.child
    checker.scope = module
    for node in unit.body.stmts:
      if node.tag in ["function", "extern-function"]:
        let name = if node.tag == "function": ast.Function(node).name.text else: ast.External(node).name.text
        let callable = checker.signature(node)
        module.define(name, callable)
        if node.tag == "extern-function":
          let external = ast.External(node)
          let foreign = if external.symbol.len > 0:
            external.symbol else: external.name.text
          if external.abi == "runtime.memory" and
              foreign in ["system", "arena"]:
            checker.allocators.add(if callable.ret.kind == "error":
              callable.ret.elem else: callable.ret)
      elif node.tag == "alias" and ast.Alias(node).body.tag == "choice":
        let alias = ast.Alias(node)
        let choice = checker.definitions[alias.name.text]
        for name in choice.variants.keys:
          module.define(name, checker.constructor(alias, choice, name))
    for node in unit.body.stmts:
      if node.tag in ["constant", "mutable"]:
        let declared = if node.tag == "constant":
          ast.Constant(node).type else: ast.Mutable(node).type
        let expression = if node.tag == "constant":
          ast.Constant(node).value else: ast.Mutable(node).value
        let name = if node.tag == "constant":
          ast.Constant(node).name.text else: ast.Mutable(node).name.text
        let data = if declared != nil: checker.annotation(declared)
          elif expression.tag in ["integer", "decimal", "text", "true",
              "false", "nothing", "null"]: checker.infer(expression, module,
                if declared != nil: checker.annotation(declared) else: nil)
          else: unknown()
        module.define(name, data)
    for node in unit.body.stmts: checker.statement(node, module)
