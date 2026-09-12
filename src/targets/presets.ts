export interface Target {
  arch: string;
  os: string;
  abi: string;
  libc: string;
  cpu: string;
  features: string[];
}

export const presets: Record<string, Target> = {
  "linux-x64": { arch: "x86_64", os: "linux", abi: "gnu", libc: "glibc", cpu: "x86_64", features: [] },
  "linux-arm64": { arch: "aarch64", os: "linux", abi: "gnu", libc: "glibc", cpu: "aarch64", features: [] },
  "linux-musl-x64": { arch: "x86_64", os: "linux", abi: "musl", libc: "musl", cpu: "x86_64", features: [] },
  "macos-arm64": { arch: "aarch64", os: "macos", abi: "none", libc: "system", cpu: "apple_m1", features: [] },
  "windows-x64": { arch: "x86_64", os: "windows", abi: "msvc", libc: "msvcrt", cpu: "x86_64", features: [] },
  "wasi": { arch: "wasm32", os: "wasi", abi: "none", libc: "wasi", cpu: "generic", features: [] },
};

export function resolve(name: string): Target {
  const target = presets[name];
  if (!target) {
    throw new Error(`Unknown target preset: ${name}`);
  }
  return target;
}