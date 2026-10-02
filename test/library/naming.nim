import std/[os, strutils]

let library = currentSourcePath.parentDir.parentDir.parentDir / "lib"

for path in walkDirRec(library):
  if path.endsWith(".iv"):
    let file = path.splitFile.name
    doAssert file == file.toLowerAscii and '-' notin file and '_' notin file,
      path & " must use a single lowercase word for its filename"
    for line in path.lines:
      let declaration = line.find("function ")
      if declaration >= 0:
        let start = declaration + "function ".len
        var finish = start
        while finish < line.len and line[finish] notin {' ', '[', '('}: inc finish
        let name = line[start ..< finish]
        doAssert name == name.toLowerAscii and '_' notin name,
          path & " must use a single lowercase word for function " & name
      let definition = line.find("define ")
      if definition >= 0:
        let start = definition + "define ".len
        var finish = start
        while finish < line.len and line[finish] notin {' ', '['}: inc finish
        let name = line[start ..< finish]
        let tail = if name.len > 1: name[1 .. ^1] else: ""
        doAssert '_' notin name and tail == tail.toLowerAscii,
          path & " must use a single capitalized word for type " & name
