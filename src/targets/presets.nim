import std/tables

type
  Target* = object
    arch*: string
    os*: string
    abi*: string
    libc*: string
    cpu*: string
    features*: seq[string]

let presets* = {
  "linux-x64-v3": Target(arch: "x86_64", os: "linux", abi: "gnu", libc: "glibc", cpu: "x86-64-v3", features: @["avx2"]),
  "windows-x64-v3": Target(arch: "x86_64", os: "windows", abi: "msvc", libc: "msvcrt", cpu: "x86-64-v3", features: @["avx2"]),
  "linux-x64": Target(arch: "x86_64", os: "linux", abi: "gnu", libc: "glibc", cpu: "x86_64"),
  "linux-arm64": Target(arch: "aarch64", os: "linux", abi: "gnu", libc: "glibc", cpu: "aarch64"),
  "linux-musl-x64": Target(arch: "x86_64", os: "linux", abi: "musl", libc: "musl", cpu: "x86_64"),
  "macos-arm64": Target(arch: "aarch64", os: "macos", abi: "none", libc: "system", cpu: "apple_m1"),
  "windows-x64": Target(arch: "x86_64", os: "windows", abi: "msvc", libc: "msvcrt", cpu: "x86_64"),
  "windows-arm64": Target(arch: "aarch64", os: "windows", abi: "msvc", libc: "msvcrt", cpu: "generic"),
  "wasi": Target(arch: "wasm32", os: "wasi", abi: "none", libc: "wasi", cpu: "generic"),
  "wasi-threads": Target(arch: "wasm32", os: "wasi", abi: "none", libc: "wasi", cpu: "generic", features: @["threads"]),
  "wasm-freestanding": Target(arch: "wasm32", os: "freestanding", abi: "none", libc: "none", cpu: "generic"),
  "aarch64-freestanding": Target(arch: "aarch64", os: "freestanding", abi: "none", libc: "none", cpu: "generic"),
  "riscv64-freestanding": Target(arch: "riscv64", os: "freestanding", abi: "none", libc: "none", cpu: "generic")
}.toTable

proc resolve*(name: string): Target =
  if name notin presets: raise newException(ValueError, "Unknown target preset: " & name)
  presets[name]
