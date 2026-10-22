import std/[os, strutils]
import ../pkg/hash

when defined(windows):
  import std/winlean
else:
  import std/posix

type Guard* = object
  when defined(windows):
    handle: Handle
  else:
    descriptor: cint

proc directory*(root, file, name: string; line: int; backend, mode: string): string =
  var identity = absolutePath(file).replace('\\', '/')
  when defined(windows): identity = identity.toLowerAscii()
  let digest = digest(identity & "\0" & name & "\0" & $line)
  var label = ""
  for c in splitFile(file).name:
    if c.isAlphaNumeric: label.add(c)
    elif label.len > 0 and label[^1] != '_': label.add('_')
    if label.len == 24: break
  if label.len == 0: label = "suite"
  let selected = getEnv("FOO_TEST_ARTIFACT_DIR")
  let base = if selected.len > 0: absolutePath(selected)
    else: root / ".artifacts" / "test"
  base / "foo" / backend / mode / (label & "_" & digest[0 ..< 16])

proc acquire*(directory: string): Guard =
  createDir(directory)
  let path = directory / ".lock"
  when defined(windows):
    while true:
      result.handle = createFileW(newWideCString(path),
        DWORD(GENERIC_READ or GENERIC_WRITE), 0, nil, DWORD(OPEN_ALWAYS),
        DWORD(FILE_ATTRIBUTE_NORMAL), Handle(0))
      if result.handle != INVALID_HANDLE_VALUE: return
      if getLastError() != 32:
        raise newException(IOError, "Cannot lock test build directory: " & path)
      sleep(50)
  else:
    result.descriptor = posix.open(path.cstring, O_CREAT or O_RDWR,
      Mode(S_IRUSR or S_IWUSR))
    if result.descriptor < 0:
      raise newException(IOError, "Cannot open test build lock: " & path)
    if lockf(result.descriptor, F_LOCK, 0) != 0:
      discard posix.close(result.descriptor)
      raise newException(IOError, "Cannot lock test build directory: " & path)

proc release*(guard: var Guard) =
  when defined(windows):
    if guard.handle != INVALID_HANDLE_VALUE:
      discard closeHandle(guard.handle)
      guard.handle = INVALID_HANDLE_VALUE
  else:
    if guard.descriptor >= 0:
      discard lockf(guard.descriptor, F_ULOCK, 0)
      discard posix.close(guard.descriptor)
      guard.descriptor = -1
