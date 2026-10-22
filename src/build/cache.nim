import ../pkg/cache as implementation

type Cache* = implementation.Cache

proc cache*(artifact, key: string): Cache = implementation.cache(artifact, key)
proc valid*(selected: Cache): bool = implementation.valid(selected)
proc save*(selected: Cache; outputs: seq[string] = @[]) = implementation.save(selected, outputs)
proc executable*(command: string): string = implementation.executable(command)
proc digest*(path: string): string = implementation.digest(path)
proc tool*(path, directory: string): string = implementation.tool(path, directory)
