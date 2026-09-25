import std/strutils
import std/sets
import ./node
import ../sema/bindings

proc indent(depth: int): string = "  ".repeat(depth)

proc escapeText(text: string): string =
  for ch in text:
    case ch
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\t': result.add("\\t")
    of '\r': result.add("\\r")
    of '\0': result.add("\\0")
    else: result.add(ch)

proc text(value: string): string =
  if '\n' notin value: return "\"" & escapeText(value) & "\""
  var pieces: seq[string]
  let parts = value.split('\n')
  for index in 0 ..< parts.len:
    let part = parts[index]
    if index > 0: pieces.add("newline")
    if part.len > 0: pieces.add("\"" & escapeText(part) & "\"")
  if pieces.len == 1: pieces[0] else: "(" & pieces.join(" plus ") & ")"

proc print*(value: Node; depth: int = 0): string

proc printAttributes(attributes: seq[string]): string =
  for attribute in attributes: result.add("#[" & attribute & "] ")

proc printTypeParams(params: seq[TypeParam]): string =
  if params.len == 0: return ""
  var values: seq[string]
  for param in params: values.add(param.name.text)
  "[" & values.join(", ") & "]"

proc constraints(params: seq[TypeParam]; clauses: seq[Constraint]): string =
  var seen = initHashSet[string]()
  var values: seq[string]
  for param in params:
    if param.bound != nil:
      let value = param.name.text & " is " & param.bound.text
      if value notin seen: seen.incl(value); values.add(value)
  for clause in clauses:
    let value = clause.subject.text & " is " & clause.trait.text
    if value notin seen: seen.incl(value); values.add(value)
  if values.len > 0: " where " & values.join(", ") else: ""

proc printBlock(value: Block; depth: int): string =
  if value.stmts.len == 0: return "{ }"
  var statements: seq[string]
  for statement in value.stmts: statements.add(print(statement, depth + 1))
  "{\n" & statements.join("\n") & "\n" & indent(depth) & "}"

proc print*(value: Node; depth: int = 0): string =
  if value == nil: return ""
  case value.tag
  of "program":
    var units: seq[string]
    for item in Program(value).units: units.add(print(item))
    result = units.join("\n\n")
  of "unit":
    var statements: seq[string]
    for statement in Unit(value).body.stmts: statements.add(print(statement, depth))
    result = statements.join("\n")
  of "test": result = indent(depth) & "test " & text(TestBlock(value).name.value) & " " & printBlock(TestBlock(value).body, depth)
  of "eval": result = indent(depth) & "eval " & printBlock(EvalBlock(value).body, depth)
  of "reflect": result = "reflect[" & print(Reflect(value).`type`) & "]()"
  of "embed":
    let item = Embed(value)
    result = "embed" & (if item.`type` != nil: "[" & print(item.`type`) & "]" else: "") & "(\"" & escapeText(item.path) & "\")"
  of "error-chain": result = print(ErrorChain(value).expr) & " context " & print(ErrorChain(value).context)
  of "constant":
    let item = Constant(value)
    result = indent(depth) & (if item.public: "public " else: "") & "constant " & item.name.text &
      (if item.`type` != nil: " of type " & print(item.`type`) else: "") & " is " & print(item.value) & "."
  of "mutable":
    let item = Mutable(value)
    result = indent(depth) & (if item.public: "public " else: "") & "dynamic " & item.name.text &
      (if item.`type` != nil: " of type " & print(item.`type`) else: "") & " is " & print(item.value) & "."
  of "function":
    let item = Function(value)
    var params: seq[string]
    for param in item.params: params.add(print(param))
    let name = if item.name.text == "start": "start" else: "function " & item.name.text
    result = indent(depth) & printAttributes(item.attributes) & (if item.public: "public " else: "") & name &
      printTypeParams(item.typeParams) & "(" & params.join(", ") & ")" &
      (if item.returnType != nil: " giving " & print(item.returnType) else: "") &
      (if item.abi.len > 0: " for " & item.abi else: "") & constraints(item.typeParams, item.constraints) & " " & printBlock(item.body, depth)
  of "alias":
    let item = Alias(value)
    var body = print(item.body, depth)
    result = indent(depth) & printAttributes(item.attributes) & (if item.public: "public " else: "") & "define " & item.name.text &
      printTypeParams(item.typeParams) & " as " & body
    if item.derives != nil:
      var traits: seq[string]
      for trait in item.derives.traits: traits.add(trait.text)
      result.add(" derives " & traits.join(", "))
    result.add(constraints(item.typeParams, item.constraints) & ".")
  of "use":
    let item = Use(value)
    let target = if item.path.len > 0: "\"" & escapeText(item.path) & "\"" else: item.name.text
    result = indent(depth) & (if item.public: "public " else: "") & "use " & target & (if item.alias != nil: " as " & item.alias.text else: "") & "."
  of "extern-function":
    let item = ExternFunction(value)
    var params: seq[string]
    for param in item.params: params.add(print(param))
    let prefix = indent(depth) & (if item.public: "public " else: "")
    if item.native.code.len > 0:
      result = prefix & "native" & (if item.native.substrate == "foo": "" else: " " & item.native.substrate) & " function " & item.name.text &
        "(" & params.join(", ") & ") giving " & print(item.returnType) & " {" & item.native.code & "}"
    else:
      result = prefix & "use \"" & escapeText(provider(item.abi)) & "\" function " & item.name.text & printTypeParams(item.typeParams) &
        "(" & params.join(", ") & ") giving " & print(item.returnType) & "."
  of "c-import": result = indent(depth) & "use c \"" & escapeText(CImport(value).header) & "\"."
  of "native-zig": result = indent(depth) & "native zig {" & NativeZig(value).code & "}"
  of "native":
    let item = Native(value)
    result = indent(depth) & "native" & (if item.substrate == "foo": "" else: " " & item.substrate) & " {" & item.code & "}"
  of "asm": result = indent(depth) & "asm {" & Asm(value).code & "}"
  of "give": result = indent(depth) & "give" & (if Give(value).value != nil: " " & print(Give(value).value) else: "") & "."
  of "when":
    let item = `When`(value)
    result = indent(depth) & "when " & print(item.cond) & " " & printBlock(item.`then`, depth)
    if item.`else` != nil: result.add(" otherwise " & print(item.`else`, depth).strip())
  of "while": result = indent(depth) & "while " & print(`While`(value).cond) & " " & printBlock(`While`(value).body, depth)
  of "repeat": result = indent(depth) & "repeat until " & Repeat(value).target.text & " reaches " & print(Repeat(value).limit) & " " & printBlock(Repeat(value).body, depth)
  of "for": result = indent(depth) & "for each " & `For`(value).`bind`.text & " in " & print(`For`(value).iter) & " " & printBlock(`For`(value).body, depth)
  of "match":
    let item = Match(value)
    var cases: seq[string]
    for branch in item.cases: cases.add(print(branch, depth + 1))
    result = indent(depth) & "match " & print(item.scrutinee) & " {\n" & cases.join("\n") & "\n" & indent(depth) & "}"
  of "break": result = indent(depth) & "stop."
  of "continue": result = indent(depth) & "skip."
  of "try": result = indent(depth) & print(`Try`(value).expr) & " try."
  of "defer":
    let item = `Defer`(value)
    result = indent(depth) & "after" & (if item.error: " error" else: "") & " "
    if item.body.tag == "block": result.add(printBlock(Block(item.body), depth)) else: result.add("{ " & print(item.body) & ". }")
  of "unsafe": result = indent(depth) & "unsafe " & printBlock(Unsafe(value).body, depth)
  of "action":
    let item = Action(value)
    if item.value != nil: result = indent(depth) & print(item.value) & "."
    else:
      var args: seq[string]
      for arg in item.args: args.add(print(arg))
      result = indent(depth) & item.name.text & "(" & args.join(", ") & ")."
  of "advance": result = indent(depth) & "advance " & AdvanceStatement(value).target.text & "."
  of "unreachable-statement": result = indent(depth) & "unreachable."
  of "integer": result = Integer(value).value
  of "decimal": result = Decimal(value).value
  of "text": result = text(Text(value).value)
  of "character": result = "'" & Character(value).value & "'"
  of "true": result = "true"
  of "false": result = "false"
  of "nothing": result = "nothing"
  of "uninitialized": result = "uninitialized"
  of "unreachable": result = "unreachable"
  of "newline": result = "newline"
  of "quantity": result = Quantity(value).value & " " & Quantity(value).unit
  of "name": result = Name(value).text
  of "call":
    let item = Call(value)
    var args, types: seq[string]
    for arg in item.args: args.add(print(arg))
    for kind in item.types: types.add(print(kind))
    result = print(item.callee) & (if types.len > 0: "[" & types.join(", ") & "]" else: "") & "(" & args.join(", ") & ")"
  of "unary":
    let item = Unary(value)
    result = if item.op == "try": print(item.operand) & " try" else: item.op & " " & print(item.operand)
  of "binary":
    let operation = case Binary(value).op
      of "catch": "fallback"
      of "minus": "subtract"
      of "times": "multiply"
      of "divided by": "divide"
      of "is at least": "greater than or equal to"
      of "is at most": "less than or equal to"
      else: Binary(value).op
    result = print(Binary(value).left) & " " & operation & " " & print(Binary(value).right)
  of "group": result = "(" & print(Group(value).expr) & ")"
  of "field": result = print(Field(value).`object`) & "." & Field(value).field.text
  of "index": result = print(Index(value).`object`) & "[" & print(Index(value).index) & "]"
  of "primitive": result = Primitive(value).name & (if Primitive(value).width.len > 0: " " & Primitive(value).width else: "")
  of "array": result = "sequence of " & print(Array(value).elem)
  of "sequence": result = "sequence of " & (if Sequence(value).constant: "constant " else: "") & print(Sequence(value).elem)
  of "allocation": result = "allocate " & print(Allocation(value).size) & (if Allocation(value).owner != nil: " using " & print(Allocation(value).owner) else: "")
  of "assignment": result = indent(depth) & "set " & print(Assignment(value).target) & " to " & print(Assignment(value).value) & "."
  of "optional": result = "optional " & print(Optional(value).elem)
  of "error": result = "fallible " & print(Error(value).elem)
  of "pointer": result = "pointer to " & print(Pointer(value).elem)
  of "named": result = Named(value).name.text
  of "generic-inst":
    var args: seq[string]
    for arg in GenericInst(value).args: args.add(print(arg))
    result = GenericInst(value).name.text & "[" & args.join(", ") & "]"
  of "vector": result = "vector[" & Vector(value).length & ", " & print(Vector(value).elem) & "]"
  of "function-type":
    var params: seq[string]
    for param in FunctionType(value).params: params.add(print(param))
    result = "function taking (" & params.join(", ") & ") giving " & print(FunctionType(value).ret) &
      (if FunctionType(value).abi.len > 0: " for " & FunctionType(value).abi else: "")
  of "parameter": result = Parameter(value).name.text & " " & print(Parameter(value).`type`)
  of "constraint": result = Constraint(value).subject.text & " is " & Constraint(value).trait.text
  of "case":
    let item = `Case`(value)
    result = indent(depth) & "case " & print(item.pattern) & (if item.guard != nil: " when " & print(item.guard) else: "") & " " & printBlock(item.body, depth)
  of "block": result = printBlock(Block(value), depth)
  of "wildcard": result = "anything"
  of "variant-pattern": result = VariantPattern(value).name.text & "(" & (if VariantPattern(value).binding != nil: VariantPattern(value).binding.text else: "") & ")"
  of "record":
    let item = Record(value)
    let prefix = if item.layout.len > 0: item.layout & " " else: ""
    if item.fields.len == 0: result = prefix & "record { }"
    else:
      var fields: seq[string]
      for field in item.fields: fields.add(print(field, depth + 1))
      result = prefix & "record {\n" & fields.join("\n") & "\n" & indent(depth) & "}"
  of "choice":
    var variants: seq[string]
    for variant in Choice(value).variants: variants.add(print(variant, depth + 1))
    result = "choice {\n" & variants.join("\n") & "\n" & indent(depth) & "}"
  of "union":
    let item = Union(value)
    if item.fields.len == 0: result = "c union { }"
    else:
      var fields: seq[string]
      for field in item.fields: fields.add(print(field, depth + 1))
      result = "c union {\n" & fields.join("\n") & "\n" & indent(depth) & "}"
  of "opaque": result = "opaque"
  of "member": result = indent(depth) & printAttributes(Member(value).attributes) & Member(value).name.text & " of type " & print(Member(value).`type`) & "."
  of "variant": result = indent(depth) & Variant(value).name.text & (if Variant(value).payload != nil: "(" & print(Variant(value).payload) & ")" else: "") & (if Variant(value).value != nil: " is " & Variant(value).value.value else: "") & "."
  of "broken": result = "-- broken"
  else: result = ""
