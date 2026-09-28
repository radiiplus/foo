import std/strutils
import ../../src/opt/engine

let context = Context(backend: "c", target: "x86_64-windows-msvc",
  cpu: "x86-64-v3", mode: "release")
let selected = choose("copy", "overlap-safe", context, [
  candidate("portable", "@c", "overlap-safe", "portable fallback", 0,
    fallback = true),
  candidate("avx2", "@c", "overlap-safe", "measured AVX2 path", 20),
  candidate("unmeasured", "@c", "overlap-safe", "no evidence", 30,
    evidenced = false)
])
doAssert selected.implementation == "avx2"
doAssert not selected.fallback

let fallback = choose("task", "scoped", context, [
  candidate("threaded", "@runtime", "scoped", "portable threads", 0,
    fallback = true),
  candidate("iocp", "@runtime", "scoped", "design candidate", 10,
    evidenced = false)
])
doAssert fallback.implementation == "threaded"
doAssert fallback.fallback

let sized = choose("search", "byte search", Context(backend: "c",
  target: "x86_64-linux-gnu", mode: "release", sizeKnown: true,
  knownSize: 4096, overlapKnown: true), [
  candidate("linear", "@runtime", "byte search", "portable fallback", 0,
    fallback = true),
  candidate("vector", "@runtime", "byte search", "large Linux input", 10,
    backends = @["c"], targets = @["linux"], modes = @["release"],
    minimum = 256, overlap = 0)
])
doAssert sized.implementation == "vector"

try:
  discard choose("invalid", "contract", context, [
    candidate("candidate", "@runtime", "contract", "missing fallback", 1)
  ])
  doAssert false
except ValueError as error:
  doAssert "fallback" in error.msg

echo "execution specialization engine: ok"
