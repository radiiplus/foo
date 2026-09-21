import std/os
import ../ast/node as ast
import ../diag/[code, engine]
import ../lex/lexer
import ../parse/parser
import "./bind.nim" as binding

proc resolveHeader(header, baseDir: string; includePaths: seq[string]): string =
  let local = absolutePath(baseDir / header)
  if fileExists(local): return local
  for directory in includePaths:
    let candidate = absolutePath(baseDir / directory / header)
    if fileExists(candidate): return candidate

proc expand*(program: ast.Program; diag: Engine; baseDir: string; options = BindOptions()) =
  for unit in program.units:
    var generated, retained: seq[ast.Statement]
    for statement in unit.body.stmts:
      if statement.tag != "c-import":
        retained.add(statement)
        continue
      let importNode = ast.CImport(statement)
      let header = resolveHeader(importNode.header, baseDir, options.includePaths)
      if header.len == 0:
        diag.emit(CBinding, statement.span, "C header '" & importNode.header & "' was not found")
        diag.suggestion("Add its directory to build.c.include or use a project-relative path")
        continue
      try:
        var bindOptions = options
        bindOptions.cacheDir = absolutePath(baseDir / ".artifacts" / "bindings")
        let result = binding.`bind`(header, bindOptions)
        for issue in result.diagnostics:
          if issue.code in ["C_UNBINDABLE", "C_HEADER"]: diag.emit(CBinding, statement.span, issue.message)
        if diag.failed: continue
        let bindingDiag = newEngine()
        bindingDiag.setSource(result.source, result.bindingPath)
        let parsed = newParser(newLexer(result.source, bindingDiag).lex(), bindingDiag).parse()
        if bindingDiag.failed or parsed.units.len == 0:
          diag.emit(CBinding, statement.span, "generated bindings for '" & importNode.header & "' did not parse")
          continue
        generated.add(parsed.units[0].body.stmts)
      except CatchableError as error:
        diag.emit(CBinding, statement.span, error.msg)
    unit.body.stmts = retained & generated
