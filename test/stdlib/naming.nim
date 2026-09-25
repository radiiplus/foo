import std/[os, strutils]

let standardLibrary = currentSourcePath.parentDir.parentDir.parentDir / "std"

for path in walkDirRec(standardLibrary):
  if path.endsWith(".iv"):
    for line in path.lines:
      let declaration = line.find("function ")
      if declaration >= 0:
        let start = declaration + "function ".len
        var finish = start
        while finish < line.len and line[finish] notin {' ', '[', '('}: inc finish
        let name = line[start ..< finish]
        doAssert '_' notin name, path & " declares snake-case std function " & name
