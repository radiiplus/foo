import std/os
import ../ast/node as ast
import ../diag/[code, engine]
import ../lex/lexer
import ../ast/parser
import "./bind.nim" as binding

proc header(header, dir: string; includes: seq[string]): string =
  let local = absolutePath(dir / header)
  if fileExists(local): return local
  for directory in includes:
    let candidate = absolutePath(dir / directory / header)
    if fileExists(candidate): return candidate

proc expand*(program: ast.Program; diag: Engine; dir: string; options = Binding();
    dependency: proc(path: string) {.closure.} = nil) =
  for unit in program.units:
    var generated, retained: seq[ast.Statement]
    for statement in unit.body.stmts:
      if statement.tag != "c-import":
        retained.add(statement)
        continue
      let item = ast.CImport(statement)
      let header = header(item.header, dir, options.includes)
      if header.len == 0:
        diag.emit(CBinding, statement.span, "C header '" & item.header & "' was not found")
        diag.suggestion("Add its directory to build.c.include or use a project-relative path")
        continue
      try:
        var configuration = options
        configuration.cacheDir = absolutePath(dir / ".artifacts" / "bindings")
        let result = binding.`bind`(header, configuration)
        if dependency != nil:
          for path in result.dependencies: dependency(path)
        for issue in result.diagnostics:
          if issue.code in ["C_UNBINDABLE", "C_HEADER"]: diag.emit(CBinding, statement.span, issue.message)
        if diag.failed: continue
        let issues = engine()
        issues.source(result.source, result.bindingPath)
        let parsed = parser(lexer(result.source, issues).lex(), issues).parse()
        if issues.failed or parsed.units.len == 0:
          diag.emit(CBinding, statement.span, "generated bindings for '" & item.header & "' did not parse")
          continue
        generated.add(parsed.units[0].body.stmts)
      except CatchableError as error:
        diag.emit(CBinding, statement.span, error.msg)
    unit.body.stmts = retained & generated
