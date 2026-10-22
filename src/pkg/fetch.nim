import ../build/files
import ../config/project as configuration
import std/[os, osproc, sequtils, strutils]
import ./cache as cache
import ./hash as package

type Download* = object
  path*: string
  hash*: string

proc fetch*(name, source, root: string): Download =
  if source.startsWith("path+"):
    let value = source[5 .. ^1]
    let location = if value.isAbsolute: absolutePath(value) else: absolutePath(value, root)
    if not dirExists(location): raise newException(IOError, "Local dependency not found: " & location)
    return Download(path: location, hash: package.directory(location))
  if source.startsWith("git+"):
    let url = source[4 .. ^1]
    let destination = cache.directory(root) / "git" / package.buffer(url)
    if not dirExists(destination):
      if getEnv("FOO_OFFLINE") == "1": raise newException(IOError, "Offline mode: missing controlled/cached dependency " & name)
      createDir(parentDir(destination))
      let outcome = execCmdEx("git clone --depth 1 -- " & quoteShell(url) & " " & quoteShell(destination))
      if outcome.exitCode != 0:
        if dirExists(destination): removeDir(destination)
        raise newException(IOError, "Failed to clone " & url)
    return Download(path: destination, hash: package.directory(destination))
  if source.startsWith("http://") or source.startsWith("https://"):
    let loopback = source.startsWith("http://127.0.0.1") or source.startsWith("http://localhost") or source.startsWith("http://[::1]")
    if not source.startsWith("https://") and not loopback:
      raise newException(ValueError, "Dependency URLs require HTTPS (loopback HTTP is allowed for staging)")
    let destination = cache.directory(root) / "url" / package.buffer(source)
    if not dirExists(destination):
      if getEnv("FOO_OFFLINE") == "1": raise newException(IOError, "Offline mode: missing controlled/cached dependency " & name)
      createDir(destination)
      let archive = destination / "download.tar"
      let downloaded = execCmdEx("curl --fail --location --max-time 60 --output " & quoteShell(archive) & " -- " & quoteShell(source))
      if downloaded.exitCode != 0:
        files.erase(destination)
        raise newException(IOError, "Could not download package '" & name & "'")
      let listing = execCmdEx("tar -tf " & quoteShell(archive))
      let details = execCmdEx("tar -tvf " & quoteShell(archive))
      for path in listing.output.splitLines:
        if path.startsWith("/") or path.split({'/', '\\'}).anyIt(it == ".."):
          files.erase(destination)
          raise newException(ValueError, "Unsafe package archive")
      if details.output.contains("\nln ") or details.output.contains("\nh "):
        files.erase(destination)
        raise newException(ValueError, "Unsafe package archive")
      let extracted = execCmdEx("tar -xf " & quoteShell(archive) & " -C " & quoteShell(destination))
      removeFile(archive)
      if extracted.exitCode != 0 or not configuration.manifestExists(destination):
        files.erase(destination)
        raise newException(ValueError, "Archive has no project manifest")
    return Download(path: destination, hash: package.directory(destination))
  raise newException(ValueError, "Unsupported dependency source: " & source)
