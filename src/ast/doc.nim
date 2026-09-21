import std/strutils
import ./node
import ./print

proc doc*(program: Program): string =
  var lines: seq[string]
  for unit in program.units:
    for statement in unit.body.stmts:
      case statement.tag
      of "function":
        let item = Function(statement)
        if not item.public: continue
        var params, typeParams, clauses: seq[string]
        for param in item.params: params.add(print(param))
        for param in item.typeParams: typeParams.add(param.name.text)
        for clause in item.constraints: clauses.add(clause.subject.text & " is " & clause.trait.text)
        lines.add("public function " & item.name.text &
          (if typeParams.len > 0: "[" & typeParams.join(", ") & "]" else: "") &
          "(" & params.join(", ") & ")" &
          (if item.returnType != nil: " of type " & print(item.returnType) else: "") &
          (if clauses.len > 0: " where " & clauses.join(", ") else: "") & ".")
      of "extern-function":
        let item = ExternFunction(statement)
        if not item.public: continue
        var params, typeParams, clauses: seq[string]
        for param in item.params: params.add(print(param))
        for param in item.typeParams: typeParams.add(param.name.text)
        for clause in item.constraints: clauses.add(clause.subject.text & " is " & clause.trait.text)
        lines.add("public function " & item.name.text &
          (if typeParams.len > 0: "[" & typeParams.join(", ") & "]" else: "") &
          "(" & params.join(", ") & ")" &
          (if item.returnType != nil: " of type " & print(item.returnType) else: "") &
          (if clauses.len > 0: " where " & clauses.join(", ") else: "") & ".")
      of "alias":
        let item = Alias(statement)
        if item.public: lines.add(print(item))
      of "constant":
        let item = Constant(statement)
        if item.public:
          lines.add("public constant " & item.name.text &
            (if item.`type` != nil: " of type " & print(item.`type`) else: "") & ".")
      else: discard
  result = lines.join("\n")
  if lines.len > 0: result.add('\n')
