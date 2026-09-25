import std/[json, os, strutils]
import ../build/files
import ../pkg/semver

proc validName(name: string): bool =
  if name.len == 0 or not name[0].isAlphaAscii: return false
  for character in name[1 .. ^1]:
    if not (character.isAlphaNumeric or character == '-'): return false
  true

proc create*(name: string): string =
  let root = absolutePath(name)
  let projectName = root.lastPathPart
  let current = name == "."
  if fileExists(root) or (dirExists(root) and not current):
    raise newException(ValueError, "Path already exists: " & root)
  if not validName(projectName): raise newException(ValueError, "Choose a project name beginning with a letter, using letters, digits or hyphens.")
  if current:
    for file in ["project.json", "src/main.iv", ".gitignore"]:
      if fileExists(root / file):
        raise newException(ValueError, "Cannot initialize the current directory because " & file & " already exists.")
  else:
    createDir(root)
  write(root / "project.json", "{\n  \"schema\": 1,\n  \"name\": " & escapeJson(projectName) & ",\n  \"language\": \"1\",\n  \"version\": \"0.1.0\",\n  \"source\": \"src\",\n  \"requires\": \"base\",\n  \"dependencies\": {}\n}\n")
  write(root / "src" / "main.iv", "display \"Hello, world!\".\n")
  write(root / ".gitignore", ".artifacts/\n.foo/\n")
  root

proc createPackage*(name: string): string =
  let root = absolutePath(name)
  let packageName = root.lastPathPart
  let current = name == "."
  if fileExists(root) or (dirExists(root) and not current):
    raise newException(ValueError, "Path already exists: " & root)
  if not validName(packageName) or packageName != packageName.toLowerAscii():
    raise newException(ValueError, "Choose a lowercase package name beginning with a letter, using letters, digits or hyphens.")
  if current:
    for file in ["project.json", "src/main.iv", "README.md", ".gitignore"]:
      if fileExists(root / file):
        raise newException(ValueError, "Cannot initialize the current directory because " & file & " already exists.")
  else:
    createDir(root)
  write(root / "project.json", "{\n" &
    "  \"schema\": 1,\n" &
    "  \"name\": " & escapeJson(packageName) & ",\n" &
    "  \"language\": \"1\",\n" &
    "  \"version\": \"0.1.0\",\n" &
    "  \"description\": \"A Foo package.\",\n" &
    "  \"category\": " & escapeJson(packageName) & ",\n" &
    "  \"tags\": [],\n" &
    "  \"license\": \"MIT\",\n" &
    "  \"compatible\": true,\n" &
    "  \"platforms\": [],\n" &
    "  \"repository\": \"https://github.com/owner/" & packageName & "\",\n" &
    "  \"source\": \"src\",\n" &
    "  \"requires\": \"base\",\n" &
    "  \"dependencies\": {}\n" &
    "}\n")
  write(root / "src" / "main.iv", "public constant version is \"0.1.0\".\n")
  write(root / "README.md", "# " & packageName & "\n\n" &
    "Describe what this package does.\n\n" &
    "## Installation\n\n```text\nfoo add " & packageName & "\nfoo install\n```\n\n" &
    "## Usage\n\nDocument the public API and include practical examples here.\n\n" &
    "## Compatibility\n\nDocument supported platforms and system requirements here.\n")
  write(root / ".gitignore", ".artifacts/\n.foo/\n")
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
    if character == '@' and index == 0: continue
    if character == '/':
      if slash or index == 0 or index + 1 == name.len: return false
      slash = true
    elif not (character.isAlphaNumeric or character == '-' or character == '_'):
      return false
  true

proc exactVersion(value: string): bool =
  let parts = value.split('.')
  if parts.len != 3: return false
  for part in parts:
    if part.len == 0 or (part.len > 1 and part[0] == '0'): return false
    for character in part:
      if not character.isDigit: return false
  true

proc dependencySource*(name, source: string): string =
  if source.startsWith("registry+"):
    let prefix = "registry+" & name & "@"
    if not source.startsWith(prefix):
      raise newException(ValueError, "Registry source must match the dependency name.")
    result = source[prefix.len .. ^1]
  elif exactVersion(source) or source.startsWith("^") or source.startsWith("~"):
    discard parseConstraint(source)
    result = source
  elif source.startsWith("path+"):
    result = "path+" & source[5 .. ^1].replace('\\', '/')
  elif source.startsWith("git+"):
    result = source
  elif source.startsWith("https://") or source.startsWith("http://"):
    result = if source.toLowerAscii().contains(".git"):
      "git+" & source else: source
  elif source.len > 0:
    result = "path+" & source.replace('\\', '/')
  else:
    raise newException(ValueError, "A dependency source or registry version is required.")

proc dependency*(command, name: string; source = ""; root = getCurrentDir()) =
  if command notin ["add", "remove"]: raise newException(ValueError, "Unknown dependency command")
  if not validDependencyName(name): raise newException(ValueError, "Invalid dependency name.")
  let file = root / "project.json"
  if not fileExists(file): raise newException(IOError, "project.json not found")
  var manifest = parseJson(readFile(file))
  if not manifest.hasKey("dependencies") or manifest["dependencies"].kind != JObject:
    manifest["dependencies"] = newJObject()
  if command == "remove":
    var removed = false
    for field in ["dependencies", "devDependencies", "optionalDependencies"]:
      if manifest.hasKey(field) and manifest[field].kind == JObject and manifest[field].hasKey(name):
        manifest[field].delete(name); removed = true
    if manifest.hasKey("platformDependencies") and manifest["platformDependencies"].kind == JObject:
      for _, dependencies in manifest["platformDependencies"]:
        if dependencies.kind == JObject and dependencies.hasKey(name):
          dependencies.delete(name); removed = true
    if not removed: raise newException(ValueError, "No dependency named '" & name & "'.")
  else:
    if manifest["dependencies"].hasKey(name): raise newException(ValueError, "Dependency '" & name & "' already exists; edit its exact source in project.json.")
    manifest["dependencies"][name] = %dependencySource(name, source)
  write(file, pretty(manifest) & "\n")
