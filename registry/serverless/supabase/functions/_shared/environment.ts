export function setting(name: string) {
  const runtime = globalThis as typeof globalThis & {
    Deno?: { env: { get: (key: string) => string | undefined } };
    process?: { env: Record<string, string | undefined> };
  };
  return runtime.Deno?.env.get(name) ?? runtime.process?.env[name];
}

export function requiredSetting(name: string) {
  const value = setting(name);
  if (!value) throw new Error(`${name} is not configured`);
  return value;
}
