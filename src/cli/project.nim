import std/[json, os, strutils]
import ../build/files
import ../pkg/semver
import ../config/project as configuration
import ../config/source as syntax

const
  icon = staticRead("../../installers/assets/installer.ico")
  defaultVector = staticRead("../../assets/dark.svg")

proc valid(name: string): bool =
  if name.len == 0 or not name[0].isAlphaAscii: return false
  for character in name[1 .. ^1]:
    if not (character.isAlphaNumeric or character == '-'): return false
  true

proc create*(name: string): string =
  let root = absolutePath(name)
  let identifier = root.lastPathPart
  let current = name == "."
  if fileExists(root) or (dirExists(root) and not current):
    raise newException(ValueError, "Path already exists: " & root)
  if not valid(identifier): raise newException(ValueError, "Choose a project name beginning with a letter, using letters, digits or hyphens.")
  if current:
    for file in ["project.ivc", "src/main.iv", "test/main.iv",
        "benchmark/main.iv", "assets/icon.ico", "assets/icon.svg", ".gitignore"]:
      if fileExists(root / file):
        raise newException(ValueError, "Cannot initialize the current directory because " & file & " already exists.")
  else:
    createDir(root)
  write(root / "project.ivc", syntax.render(%*{"project": {
    "name": identifier,
    "version": "0.1.0", "source": "src", "entry": "src/main.iv",
    "entries": {},
    "build": {"output": "output"}
  }}, "project"))
  write(root / "src" / "main.iv", "display \"Hello, world!\".\n")
  write(root / "test" / "main.iv", "use testing as check.\n\ntest \"project starts\" {\n  check.expect(true).\n}\n")
  write(root / "benchmark" / "main.iv", "-- Replace this loop with work you want to measure.\ndynamic counter is 0.\nwhile counter less than 10`000 {\n  set counter to counter plus 1.\n}\n")
  write(root / "assets" / "icon.ico", icon)
  write(root / "assets" / "icon.svg", defaultVector)
  write(root / ".gitignore", ".artifacts/\n.foo/\noutput/\nrelease/\n")
  root

proc package*(name: string): string =
  let root = absolutePath(name)
  let label = root.lastPathPart
  let current = name == "."
  if fileExists(root) or (dirExists(root) and not current):
    raise newException(ValueError, "Path already exists: " & root)
  if not valid(label) or label != label.toLowerAscii():
    raise newException(ValueError, "Choose a lowercase package name beginning with a letter, using letters, digits or hyphens.")
  if current:
    for file in ["project.ivc", "src/main.iv", "test/main.iv",
        "benchmark/main.iv", "README.md", ".gitignore"]:
      if fileExists(root / file):
        raise newException(ValueError, "Cannot initialize the current directory because " & file & " already exists.")
  else:
    createDir(root)
  write(root / "project.ivc", syntax.render(%*{"project": {
    "name": label, "version": "0.1.0",
    "description": "A Foo package.", "category": label, "tags": [],
    "license": "MIT", "compatible": true, "platforms": [],
    "repository": "https://github.com/owner/" & label,
    "source": "src",
    "build": {"output": "output"}
  }}, "project"))
  write(root / "src" / "main.iv", "public constant version is \"0.1.0\".\n")
  write(root / "test" / "main.iv", "use testing as check.\n\ntest \"package loads\" {\n  check.expect(true).\n}\n")
  write(root / "benchmark" / "main.iv", "-- Replace this loop with package work you want to measure.\ndynamic counter is 0.\nwhile counter less than 10`000 {\n  set counter to counter plus 1.\n}\n")
  write(root / "README.md", "# " & label & "\n\n" &
    "Describe what this package does.\n\n" &
    "## Installation\n\n```text\nfoo add " & label & "\nfoo install\n```\n\n" &
    "## Usage\n\nDocument the public API and include practical examples here.\n\n" &
    "## Compatibility\n\nDocument supported platforms and system requirements here.\n")
  write(root / ".gitignore", ".artifacts/\n.foo/\noutput/\nrelease/\n")
  root

proc clean*(root = getCurrentDir()) =
  for name in ["build", "test", "benchmark", "bindings", "cache", ".cap", "config"]:
    let target = confined(root, ".artifacts/" & name)
    if dirExists(target): files.erase(target)
    elif fileExists(target): removeFile(target)
  let manifest = configuration.manifestPath(root)
  var output = "output"
  var source = "src"
  if fileExists(manifest):
    let node = configuration.readProject(root)
    source = node.getOrDefault("source").getStr("src")
    if node.hasKey("build") and node["build"].kind == JObject:
      output = node["build"].getOrDefault("output").getStr("output")
  var protected = @["src", "test", "benchmark"]
  if source notin [".", "src"]: protected.add(source)
  let target = destination(root, output, protected)
  if dirExists(target): files.erase(target)
  elif fileExists(target): removeFile(target)

proc dependency(name: string): bool =
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

proc exact(value: string): bool =
  let parts = value.split('.')
  if parts.len != 3: return false
  for part in parts:
    if part.len == 0 or (part.len > 1 and part[0] == '0'): return false
    for character in part:
      if not character.isDigit: return false
  true

proc origin*(name, source: string): string =
  if source.startsWith("registry+"):
    let prefix = "registry+" & name & "@"
    if not source.startsWith(prefix):
      raise newException(ValueError, "Registry source must match the dependency name.")
    result = source[prefix.len .. ^1]
  elif exact(source) or source.startsWith("^") or source.startsWith("~"):
    discard constraint(source)
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

proc origin*(name, source, root: string): string =
  result = origin(name, source)
  if result.startsWith("path+"):
    let value = result[5 .. ^1]
    let absolute = if value.isAbsolute: absolutePath(value) else: absolutePath(value, root)
    result = "path+" & relativePath(absolute, root).replace('\\', '/')

proc dependency*(command, name: string; source = ""; root = getCurrentDir()) =
  if command notin ["add", "remove"]: raise newException(ValueError, "Unknown dependency command")
  if not dependency(name): raise newException(ValueError, "Invalid dependency name.")
  let file = configuration.manifestPath(root)
  if not fileExists(file): raise newException(IOError, "Project manifest not found")
  var manifest = configuration.readProject(root)
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
    if manifest["dependencies"].hasKey(name): raise newException(ValueError, "Dependency '" & name & "' already exists; edit its exact source in " & file.lastPathPart & ".")
    manifest["dependencies"][name] = %origin(name, source, root)
  configuration.writeProject(root, manifest)
