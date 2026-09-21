import ../pkg/cache as packageCache

type Cache* = packageCache.Cache

proc newCache*(artifact, key: string): Cache = packageCache.newCache(artifact, key)
proc valid*(cache: Cache): bool = packageCache.valid(cache)
proc save*(cache: Cache; outputs: seq[string] = @[]) = packageCache.save(cache, outputs)
proc executable*(command: string): string = packageCache.executable(command)
proc digest*(path: string): string = packageCache.digest(path)
proc tool*(path, directory: string): string = packageCache.tool(path, directory)
