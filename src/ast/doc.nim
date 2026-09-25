import std/strutils
import ./node
import ./print

type PublicItem* = object
  kind*: string
  name*: string
  declaration*: string
  start*: int

proc publicItems*(program: Program): seq[PublicItem] =
  for unit in program.units:
    for statement in unit.body.stmts:
      var item: PublicItem
      case statement.tag
      of "function":
        let value = Function(statement)
        if not value.public: continue
        var params, typeParams, clauses: seq[string]
        for param in value.params: params.add(print(param))
        for param in value.typeParams: typeParams.add(param.name.text)
        for clause in value.constraints: clauses.add(clause.subject.text & " is " & clause.trait.text)
        item = PublicItem(kind: "function", name: value.name.text,
          declaration: "public function " & value.name.text &
            (if typeParams.len > 0: "[" & typeParams.join(", ") & "]" else: "") &
            "(" & params.join(", ") & ")" &
            (if value.returnType != nil: " of type " & print(value.returnType) else: "") &
            (if clauses.len > 0: " where " & clauses.join(", ") else: "") & ".")
      of "extern-function":
        let value = ExternFunction(statement)
        if not value.public: continue
        var params, typeParams, clauses: seq[string]
        for param in value.params: params.add(print(param))
        for param in value.typeParams: typeParams.add(param.name.text)
        for clause in value.constraints: clauses.add(clause.subject.text & " is " & clause.trait.text)
        item = PublicItem(kind: "function", name: value.name.text,
          declaration: "public function " & value.name.text &
            (if typeParams.len > 0: "[" & typeParams.join(", ") & "]" else: "") &
            "(" & params.join(", ") & ")" &
            (if value.returnType != nil: " of type " & print(value.returnType) else: "") &
            (if clauses.len > 0: " where " & clauses.join(", ") else: "") & ".")
      of "alias":
        let value = Alias(statement)
        if not value.public: continue
        item = PublicItem(kind: "type", name: value.name.text, declaration: print(value))
      of "constant":
        let value = Constant(statement)
        if not value.public: continue
        item = PublicItem(kind: "constant", name: value.name.text,
          declaration: "public constant " & value.name.text &
            (if value.`type` != nil: " of type " & print(value.`type`) else: "") & ".")
      of "mutable":
        let value = Mutable(statement)
        if not value.public: continue
        item = PublicItem(kind: "value", name: value.name.text,
          declaration: "public dynamic " & value.name.text &
            (if value.`type` != nil: " of type " & print(value.`type`) else: "") & ".")
      else: continue
      item.start = statement.span.start
      result.add(item)

proc doc*(program: Program): string =
  var lines: seq[string]
  for item in publicItems(program): lines.add(item.declaration)
  result = lines.join("\n")
  if lines.len > 0: result.add('\n')
