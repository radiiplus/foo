import std/[os, osproc, sequtils, strutils]
import ./cache as packageCache
import ./hash

type FetchResult* = object
  path*: string
  hash*: string

proc removeTree(path: string) =
  if not dirExists(path): return
  for kind, child in walkDir(path):
    if kind == pcDir: removeTree(child)
    else: removeFile(child)
  removeDir(path)

proc fetchDep*(name, source, root: string): FetchResult =
  if source.startsWith("path+"):
    let localPath = absolutePath(root / source[5 .. ^1])
    if not dirExists(localPath): raise newException(IOError, "Local dependency not found: " & localPath)
    return FetchResult(path: localPath, hash: hashDirectory(localPath))
  if source.startsWith("git+"):
    let url = source[4 .. ^1]
    let destination = packageCache.getCacheDir(root) / "git" / hashBuffer(url)
    if not dirExists(destination):
      createDir(parentDir(destination))
      let result = execCmdEx("git clone --depth 1 -- " & quoteShell(url) & " " & quoteShell(destination))
      if result.exitCode != 0:
        if dirExists(destination): removeDir(destination)
        raise newException(IOError, "Failed to clone " & url)
    return FetchResult(path: destination, hash: hashDirectory(destination))
  if source.startsWith("http://") or source.startsWith("https://"):
    let loopback = source.startsWith("http://127.0.0.1") or source.startsWith("http://localhost") or source.startsWith("http://[::1]")
    if not source.startsWith("https://") and not loopback:
      raise newException(ValueError, "Dependency URLs require HTTPS (loopback HTTP is allowed for staging)")
    let destination = packageCache.getCacheDir(root) / "url" / hashBuffer(source)
    if not dirExists(destination):
      createDir(destination)
      let archive = destination / "download.tar"
      let downloaded = execCmdEx("curl --fail --location --max-time 60 --output " & quoteShell(archive) & " -- " & quoteShell(source))
      if downloaded.exitCode != 0:
        removeTree(destination)
        raise newException(IOError, "Could not download package '" & name & "'")
      let listing = execCmdEx("tar -tf " & quoteShell(archive))
      let details = execCmdEx("tar -tvf " & quoteShell(archive))
      for path in listing.output.splitLines:
        if path.startsWith("/") or path.split({'/', '\\'}).anyIt(it == ".."):
          removeTree(destination)
          raise newException(ValueError, "Unsafe package archive")
      if details.output.contains("\nln ") or details.output.contains("\nh "):
        removeTree(destination)
        raise newException(ValueError, "Unsafe package archive")
      let extracted = execCmdEx("tar -xf " & quoteShell(archive) & " -C " & quoteShell(destination))
      removeFile(archive)
      if extracted.exitCode != 0 or not fileExists(destination / "project.json"):
        removeTree(destination)
        raise newException(ValueError, "Archive has no project.json")
    return FetchResult(path: destination, hash: hashDirectory(destination))
  raise newException(ValueError, "Unsupported dependency source: " & source)
