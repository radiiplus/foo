import std/[algorithm, os, sequtils, strutils]

const roundConstants: array[64, uint32] = [
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

proc rotateRight(value: uint32; amount: int): uint32 =
  (value shr amount) or (value shl (32 - amount))

proc add32(values: varargs[uint32]): uint32 =
  var total: uint64
  for value in values: total = (total + uint64(value)) and 0xffffffff'u64
  uint32(total)

proc sha256(data: openArray[byte]): array[32, byte] =
  var padded = newSeq[byte](data.len + 1)
  for index, value in data: padded[index] = value
  padded[data.len] = 0x80
  while padded.len mod 64 != 56: padded.add(0)
  let bitLength = uint64(data.len) * 8'u64
  for shift in countdown(7, 0): padded.add(byte((bitLength shr (shift * 8)) and 0xff))
  var state = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  var schedule: array[64, uint32]
  for offset in countup(0, padded.len - 64, 64):
    for index in 0 ..< 16:
      let base = offset + index * 4
      schedule[index] = (uint32(padded[base]) shl 24) or (uint32(padded[base + 1]) shl 16) or
        (uint32(padded[base + 2]) shl 8) or uint32(padded[base + 3])
    for index in 16 ..< 64:
      let first = rotateRight(schedule[index - 15], 7) xor rotateRight(schedule[index - 15], 18) xor (schedule[index - 15] shr 3)
      let second = rotateRight(schedule[index - 2], 17) xor rotateRight(schedule[index - 2], 19) xor (schedule[index - 2] shr 10)
      schedule[index] = add32(schedule[index - 16], first, schedule[index - 7], second)
    var a = state[0]; var b = state[1]; var c = state[2]; var d = state[3]
    var e = state[4]; var f = state[5]; var g = state[6]; var h = state[7]
    for index in 0 ..< 64:
      let sum1 = rotateRight(e, 6) xor rotateRight(e, 11) xor rotateRight(e, 25)
      let choice = (e and f) xor ((not e) and g)
      let first = add32(h, sum1, choice, roundConstants[index], schedule[index])
      let sum0 = rotateRight(a, 2) xor rotateRight(a, 13) xor rotateRight(a, 22)
      let majority = (a and b) xor (a and c) xor (b and c)
      let second = add32(sum0, majority)
      h = g; g = f; f = e; e = add32(d, first); d = c; c = b; b = a; a = add32(first, second)
    state[0] = add32(state[0], a); state[1] = add32(state[1], b); state[2] = add32(state[2], c); state[3] = add32(state[3], d)
    state[4] = add32(state[4], e); state[5] = add32(state[5], f); state[6] = add32(state[6], g); state[7] = add32(state[7], h)
  for index, value in state:
    result[index * 4] = byte(value shr 24); result[index * 4 + 1] = byte(value shr 16)
    result[index * 4 + 2] = byte(value shr 8); result[index * 4 + 3] = byte(value)

proc hashBytes*(data: openArray[byte]): string =
  var digest: seq[byte] = @[0x12'u8, 0x20'u8]
  for value in sha256(data): digest.add(value)
  for value in digest: result.add(toHex(value, 2).toLowerAscii)

proc sha256Hex*(data: openArray[byte]): string =
  for value in sha256(data): result.add(toHex(value, 2).toLowerAscii)

proc sha256Hex*(data: string): string =
  if data.len == 0: return sha256Hex([])
  sha256Hex(data.toOpenArrayByte(0, data.high))

proc hashBuffer*(data: string): string =
  if data.len == 0: return hashBytes([])
  hashBytes(data.toOpenArrayByte(0, data.high))

proc hashFile*(path: string): string = hashBuffer(readFile(path))

proc hashDirectory*(directory: string): string =
  var files: seq[string]
  for path in walkDirRec(directory):
    if not fileExists(path): continue
    let relative = relativePath(path, directory).replace('\\', '/')
    let parts = relative.split('/')
    if parts.anyIt(it in [".git", "node_modules", ".artifacts"]): continue
    files.add(path)
  files.sort()
  var content: seq[byte]
  for path in files:
    let relative = relativePath(path, directory).replace('\\', '/')
    for value in relative: content.add(byte(value))
    for value in readFile(path): content.add(byte(value))
  hashBytes(content)
