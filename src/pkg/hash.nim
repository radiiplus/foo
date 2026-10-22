import std/[algorithm, os, sequtils, strutils]
when defined(linux): import std/dynlib

const constants: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc rotate(value: uint32; amount: int): uint32 =
  (value shr amount) or (value shl (32 - amount))

proc add32(values: varargs[uint32]): uint32 =
  var total: uint64
  for value in values: total = (total + uint64(value)) and 0xffffffff'u64
  uint32(total)

const initial = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
  0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]

proc compress(state: var array[8, uint32]; input: openArray[byte]) =
  var schedule: array[64, uint32]
  for index in 0 ..< 16:
    let base = index * 4
    schedule[index] = (uint32(input[base]) shl 24) or (uint32(input[base + 1]) shl 16) or
      (uint32(input[base + 2]) shl 8) or uint32(input[base + 3])
  for index in 16 ..< 64:
    let first = rotate(schedule[index - 15], 7) xor rotate(schedule[index - 15], 18) xor (schedule[index - 15] shr 3)
    let second = rotate(schedule[index - 2], 17) xor rotate(schedule[index - 2], 19) xor (schedule[index - 2] shr 10)
    schedule[index] = add32(schedule[index - 16], first, schedule[index - 7], second)
  var a = state[0]; var b = state[1]; var c = state[2]; var d = state[3]
  var e = state[4]; var f = state[5]; var g = state[6]; var h = state[7]
  for index in 0 ..< 64:
    let sum1 = rotate(e, 6) xor rotate(e, 11) xor rotate(e, 25)
    let choice = (e and f) xor ((not e) and g)
    let first = add32(h, sum1, choice, constants[index], schedule[index])
    let sum0 = rotate(a, 2) xor rotate(a, 13) xor rotate(a, 22)
    let majority = (a and b) xor (a and c) xor (b and c)
    let second = add32(sum0, majority)
    h = g; g = f; f = e; e = add32(d, first); d = c; c = b; b = a; a = add32(first, second)
  state[0] = add32(state[0], a); state[1] = add32(state[1], b); state[2] = add32(state[2], c); state[3] = add32(state[3], d)
  state[4] = add32(state[4], e); state[5] = add32(state[5], f); state[6] = add32(state[6], g); state[7] = add32(state[7], h)

proc finish(state: array[8, uint32]): array[32, byte] =
  for index, value in state:
    result[index * 4] = byte(value shr 24); result[index * 4 + 1] = byte(value shr 16)
    result[index * 4 + 2] = byte(value shr 8); result[index * 4 + 3] = byte(value)

proc sha256(data: openArray[byte]): array[32, byte] =
  var padded = newSeq[byte](data.len + 1)
  for index, value in data: padded[index] = value
  padded[data.len] = 0x80
  while padded.len mod 64 != 56: padded.add(0)
  let length = uint64(data.len) * 8'u64
  for shift in countdown(7, 0): padded.add(byte((length shr (shift * 8)) and 0xff))
  var state = initial
  for offset in countup(0, padded.len - 64, 64):
    compress(state, padded.toOpenArray(offset, offset + 63))
  finish(state)

proc bytes*(data: openArray[byte]): string =
  var digest: seq[byte] = @[0x12'u8, 0x20'u8]
  for value in sha256(data): digest.add(value)
  for value in digest: result.add(toHex(value, 2).toLowerAscii)

proc digest*(data: openArray[byte]): string =
  for value in sha256(data): result.add(toHex(value, 2).toLowerAscii)

proc digest*(data: string): string =
  if data.len == 0: return digest([])
  digest(data.toOpenArrayByte(0, data.high))

proc buffer*(data: string): string =
  if data.len == 0: return bytes([])
  bytes(data.toOpenArrayByte(0, data.high))

proc file*(path: string): string = buffer(readFile(path))

when defined(linux):
  type
    Context = proc(): pointer {.cdecl.}
    Release = proc(context: pointer) {.cdecl.}
    Algorithm = proc(): pointer {.cdecl.}
    Initialize = proc(context, algorithm, engine: pointer): cint {.cdecl.}
    Update = proc(context, input: pointer; length: csize_t): cint {.cdecl.}
    Finalize = proc(context, output: pointer; length: ptr cuint): cint {.cdecl.}
  let crypto = block:
    let library = loadLib("libcrypto.so.3")
    if library == nil: loadLib("libcrypto.so") else: library

  proc native(path: string): string =
    if crypto == nil: return
    let create = cast[Context](symAddr(crypto, "EVP_MD_CTX_new"))
    let release = cast[Release](symAddr(crypto, "EVP_MD_CTX_free"))
    let algorithm = cast[Algorithm](symAddr(crypto, "EVP_sha256"))
    let initialize = cast[Initialize](symAddr(crypto, "EVP_DigestInit_ex"))
    let update = cast[Update](symAddr(crypto, "EVP_DigestUpdate"))
    let finalize = cast[Finalize](symAddr(crypto, "EVP_DigestFinal_ex"))
    if create == nil or release == nil or algorithm == nil or
        initialize == nil or update == nil or finalize == nil: return
    let context = create()
    if context == nil: return
    defer: release(context)
    if initialize(context, algorithm(), nil) != 1: return
    let file = open(path, fmRead)
    defer: file.close()
    var chunk: array[65536, byte]
    while true:
      let count = file.readBuffer(addr chunk[0], chunk.len)
      if count == 0: break
      if update(context, addr chunk[0], csize_t(count)) != 1: return
    var output: array[32, byte]
    var length: cuint
    if finalize(context, addr output[0], addr length) != 1 or length != 32: return
    for value in output: result.add(toHex(value, 2).toLowerAscii())

when defined(windows):
  import std/winlean
  proc open(handle: ptr pointer; algorithm, implementation: WideCString; flags: uint32): int32
    {.stdcall, dynlib: "bcrypt.dll", importc: "BCryptOpenAlgorithmProvider".}
  proc property(handle: pointer; property: WideCString; output: pointer;
      size: uint32; written: ptr uint32; flags: uint32): int32
    {.stdcall, dynlib: "bcrypt.dll", importc: "BCryptGetProperty".}
  proc create(provider: pointer; handle: ptr pointer; buffer: pointer;
      size: uint32; secret: pointer; secretSize, flags: uint32): int32
    {.stdcall, dynlib: "bcrypt.dll", importc: "BCryptCreateHash".}
  proc update(handle, input: pointer; size, flags: uint32): int32
    {.stdcall, dynlib: "bcrypt.dll", importc: "BCryptHashData".}
  proc finish(handle, output: pointer; size, flags: uint32): int32
    {.stdcall, dynlib: "bcrypt.dll", importc: "BCryptFinishHash".}
  proc destroy(handle: pointer): int32
    {.stdcall, dynlib: "bcrypt.dll", importc: "BCryptDestroyHash".}
  proc close(handle: pointer; flags: uint32): int32
    {.stdcall, dynlib: "bcrypt.dll", importc: "BCryptCloseAlgorithmProvider".}

proc checksum*(path: string): string =
  ## Content identity, with bounded memory and Windows' SHA-256 provider. The
  ## portable implementation remains the fallback; metadata never proves a hit.
  when defined(linux):
    result = native(path)
    if result.len == 64: return
  when defined(windows):
    var provider, handle: pointer
    if open(addr provider, newWideCString("SHA256"), nil, 0) >= 0:
      defer: discard close(provider, 0)
      var size, written: uint32
      if property(provider, newWideCString("ObjectLength"), addr size, 4, addr written, 0) >= 0 and size > 0:
        var storage = newSeq[byte](int(size))
        if create(provider, addr handle, addr storage[0], size, nil, 0, 0) >= 0:
          defer: discard destroy(handle)
          let file = open(path, fmRead)
          defer: file.close()
          var buffer: array[65536, byte]
          var valid = true
          while true:
            let count = file.readBuffer(addr buffer[0], buffer.len)
            if count == 0: break
            if update(handle, addr buffer[0], uint32(count), 0) < 0:
              valid = false
              break
          var digest: array[32, byte]
          if valid and finish(handle, addr digest[0], 32, 0) >= 0:
            for value in digest: result.add(toHex(value, 2).toLowerAscii())
            return
  var state = initial
  var pending: array[64, byte]
  var used = 0
  var total: uint64
  let file = open(path, fmRead)
  defer: file.close()
  var chunk: array[65536, byte]
  while true:
    let count = file.readBuffer(addr chunk[0], chunk.len)
    if count == 0: break
    total += uint64(count)
    var offset = 0
    if used > 0:
      let length = min(64 - used, count)
      for index in 0 ..< length: pending[used + index] = chunk[index]
      used += length
      offset = length
      if used == 64:
        compress(state, pending)
        used = 0
    while offset + 64 <= count:
      compress(state, chunk.toOpenArray(offset, offset + 63))
      offset += 64
    for index in offset ..< count:
      pending[used] = chunk[index]
      inc used
  var tail: array[128, byte]
  for index in 0 ..< used: tail[index] = pending[index]
  tail[used] = 0x80
  let span = if used < 56: 64 else: 128
  for index in 0 ..< 8:
    tail[span - 8 + index] = byte((total * 8'u64) shr ((7 - index) * 8))
  compress(state, tail.toOpenArray(0, 63))
  if span == 128: compress(state, tail.toOpenArray(64, 127))
  for value in finish(state): result.add(toHex(value, 2).toLowerAscii())

proc directory*(directory: string; excluded: seq[string] = @[]): string =
  var files: seq[string]
  let ignored = excluded.mapIt(
    if isAbsolute(it): absolutePath(it) else: absolutePath(it, directory))
  proc visit(path: string) =
    for kind, child in walkDir(path):
      if child.lastPathPart in [".git", ".foo", "node_modules", ".artifacts", "target"] or
          absolutePath(child) in ignored: continue
      if kind == pcDir: visit(child)
      elif kind == pcFile: files.add(child)
  visit(directory)
  files.sort()
  var content: seq[byte]
  for path in files:
    let relative = relativePath(path, directory).replace('\\', '/')
    for value in relative: content.add(byte(value))
    for value in readFile(path): content.add(byte(value))
  bytes(content)
