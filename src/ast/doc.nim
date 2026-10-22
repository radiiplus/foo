import std/strutils
import ./node
import ./print

type Entry* = object
  kind*: string
  name*: string
  declaration*: string
  start*: int

proc exports*(program: Program): seq[Entry] =
  for unit in program.units:
    for statement in unit.body.stmts:
      var item: Entry
      case statement.tag
      of "function":
        let value = Function(statement)
        if not value.public: continue
        var params, generics, clauses: seq[string]
        for param in value.params: params.add(print(param))
        for param in value.generics: generics.add(param.name.text)
        for clause in value.constraints: clauses.add(clause.subject.text & " is " & clause.trait.text)
        item = Entry(kind: "function", name: value.name.text,
          declaration: "public function " & value.name.text &
            (if generics.len > 0: "[" & generics.join(", ") & "]" else: "") &
            "(" & params.join(", ") & ")" &
            (if value.returns != nil: " giving " & print(value.returns) else: "") &
            (if clauses.len > 0: " where " & clauses.join(", ") else: "") & ".")
      of "extern-function":
        let value = External(statement)
        if not value.public: continue
        var params, generics, clauses: seq[string]
        for param in value.params: params.add(print(param))
        for param in value.generics: generics.add(param.name.text)
        for clause in value.constraints: clauses.add(clause.subject.text & " is " & clause.trait.text)
        item = Entry(kind: "function", name: value.name.text,
          declaration: "public function " & value.name.text &
            (if generics.len > 0: "[" & generics.join(", ") & "]" else: "") &
            "(" & params.join(", ") & ")" &
            (if value.returns != nil: " giving " & print(value.returns) else: "") &
            (if clauses.len > 0: " where " & clauses.join(", ") else: "") & ".")
      of "alias":
        let value = Alias(statement)
        if not value.public: continue
        item = Entry(kind: "type", name: value.name.text, declaration: print(value))
      of "constant":
        let value = Constant(statement)
        if not value.public: continue
        item = Entry(kind: "constant", name: value.name.text,
          declaration: "public constant " & value.name.text &
            (if value.`type` != nil: " of type " & print(value.`type`) else: "") & ".")
      of "mutable":
        let value = Mutable(statement)
        if not value.public: continue
        item = Entry(kind: "value", name: value.name.text,
          declaration: "public dynamic " & value.name.text &
            (if value.`type` != nil: " of type " & print(value.`type`) else: "") & ".")
      of "use":
        let value = Use(statement)
        if not value.public: continue
        item = Entry(kind: "module", name: value.name.text,
          declaration: print(value))
      else: continue
      item.start = statement.span.start
      result.add(item)

proc doc*(program: Program): string =
  var lines: seq[string]
  for item in exports(program): lines.add(item.declaration)
  result = lines.join("\n")
  if lines.len > 0: result.add('\n')
