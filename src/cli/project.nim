import std/[json, os, strutils]
import ../build/files

proc validName(name: string): bool =
  if name.len == 0 or not name[0].isAlphaAscii: return false
  for character in name[1 .. ^1]:
    if not (character.isAlphaNumeric or character == '-'): return false
  true

proc create*(name: string): string =
  let root = absolutePath(name)
  let projectName = root.lastPathPart
  if dirExists(root) or fileExists(root): raise newException(ValueError, "Path already exists: " & root)
  if not validName(projectName): raise newException(ValueError, "Choose a project name beginning with a letter, using letters, digits or hyphens.")
  createDir(root)
  write(root / "project.json", "{\n  \"schema\": 1,\n  \"name\": " & escapeJson(projectName) & ",\n  \"language\": \"1\",\n  \"version\": \"0.1.0\",\n  \"requires\": \"base\",\n  \"dependencies\": {}\n}\n")
  write(root / "main.iv", "-- Starts the application.\nstart() {\n  give nothing.\n}\n")
  write(root / ".gitignore", ".artifacts/\n")
  root

proc removeTree(path: string) =
  if not dirExists(path): return
  for kind, child in walkDir(path):
    if kind == pcDir: removeTree(child)
    else: removeFile(child)
  removeDir(path)

proc clean*(root = getCurrentDir()) =
  for name in ["build", "test", "bindings", "cache"]:
    let target = confined(root, ".artifacts/" & name)
    if dirExists(target): removeTree(target)
    elif fileExists(target): removeFile(target)

proc validDependencyName(name: string): bool =
  if name.len == 0: return false
  var slash = false
  for index, character in name:
    if character == '/':
      if slash or index == 0 or index + 1 == name.len: return false
      slash = true
    elif not (character.isAlphaNumeric or character == '-' or character == '_'):
      return false
  true

proc dependency*(command, name: string; source = ""; root = getCurrentDir()) =
  if command notin ["add", "remove"]: raise newException(ValueError, "Unknown dependency command")
  if not validDependencyName(name): raise newException(ValueError, "Invalid dependency name.")
  let file = root / "project.json"
  if not fileExists(file): raise newException(IOError, "project.json not found")
  var manifest = parseJson(readFile(file))
  if not manifest.hasKey("dependencies") or manifest["dependencies"].kind != JObject:
    manifest["dependencies"] = newJObject()
  if command == "remove":
    if not manifest["dependencies"].hasKey(name): raise newException(ValueError, "No dependency named '" & name & "'.")
    manifest["dependencies"].delete(name)
  else:
    if source.len == 0 or not (source.startsWith("path+") or source.startsWith("git+") or source.startsWith("registry+")):
      raise newException(ValueError, "Use an explicit path+, git+ or registry+ dependency source.")
    if manifest["dependencies"].hasKey(name): raise newException(ValueError, "Dependency '" & name & "' already exists; edit its exact source in project.json.")
    if source.startsWith("registry+") and not source.startsWith("registry+" & name & "@"):
      raise newException(ValueError, "Registry source must match the dependency name.")
    manifest["dependencies"][name] = %source
  write(file, pretty(manifest) & "\n")
