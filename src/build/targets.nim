import std/[strutils, tables]

type Target* = object
  arch*, os*, abi*: string

let presets* = {
  "linux-x64-v3": Target(arch: "x86_64", os: "linux", abi: "gnu"),
  "windows-x64-v3": Target(arch: "x86_64", os: "windows", abi: "msvc"),
  "linux-x64": Target(arch: "x86_64", os: "linux", abi: "gnu"),
  "linux-arm64": Target(arch: "aarch64", os: "linux", abi: "gnu"),
  "linux-musl-x64": Target(arch: "x86_64", os: "linux", abi: "musl"),
  "macos-arm64": Target(arch: "aarch64", os: "macos", abi: "none"),
  "macos-x64": Target(arch: "x86_64", os: "macos", abi: "none"),
  "windows-x64": Target(arch: "x86_64", os: "windows", abi: "msvc"),
  "uefi-x64": Target(arch: "x86_64", os: "uefi", abi: "msvc"),
  "windows-arm64": Target(arch: "aarch64", os: "windows", abi: "msvc"),
  "wasi": Target(arch: "wasm32", os: "wasi", abi: "none"),
  "wasi-threads": Target(arch: "wasm32", os: "wasi", abi: "none"),
  "wasm-freestanding": Target(arch: "wasm32", os: "freestanding", abi: "none"),
  "x64-freestanding": Target(arch: "x86_64", os: "freestanding", abi: "none"),
  "arm64-freestanding": Target(arch: "aarch64", os: "freestanding", abi: "none"),
  "riscv64-freestanding": Target(arch: "riscv64", os: "freestanding", abi: "none")
}.toTable

proc stable*(name, host: string): string =
  let arm64 = host.endsWith("arm64")
  case name
  of "linux": result = if arm64: "linux-arm64" else: "linux-x64"
  of "windows": result = if arm64: "windows-arm64" else: "windows-x64"
  of "darwin", "macos": result = if arm64: "macos-arm64" else: "macos-x64"
  of "wasm": result = "wasm-freestanding"
  of "freestanding":
    result = if arm64: "arm64-freestanding" else: "x64-freestanding"
  else: result = name

proc choose*(names: seq[string]; host: string): string =
  if names.len == 0: return host
  for name in names:
    if stable(name, host) == host: return host
  stable(names[0], host)
