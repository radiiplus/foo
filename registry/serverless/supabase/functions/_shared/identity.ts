import { setting } from "./environment.ts";

export type GitHubIdentity = {
  id: number;
  login: string;
};

export type RegistryOwner = {
  signature: string;
  login: string;
};

export class IdentityError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

export async function githubIdentity(request: Request, requestFetch: typeof fetch = fetch): Promise<GitHubIdentity> {
  const authorization = request.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ") || authorization.slice(7).trim().length === 0) {
    throw new IdentityError("GitHub authentication required", 401);
  }

  const response = await requestFetch("https://api.github.com/user", {
    headers: {
      accept: "application/vnd.github+json",
      authorization,
      "user-agent": "foo-registry",
      "x-github-api-version": "2026-03-10",
    },
  });
  if (!response.ok) throw new IdentityError("Invalid GitHub authentication", 401);
  const user = await response.json() as { id?: unknown; login?: unknown };
  if (!Number.isSafeInteger(user.id) || Number(user.id) <= 0 || typeof user.login !== "string" || user.login.length === 0) {
    throw new IdentityError("GitHub identity is missing", 403);
  }
  return { id: Number(user.id), login: user.login };
}

export async function registryOwner(identity: GitHubIdentity, secret = setting("OWNERSHIP_SECRET")): Promise<RegistryOwner> {
  if (!secret || secret.length < 32) throw new IdentityError("OWNERSHIP_SECRET must contain at least 32 characters", 503);
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const digest = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(`github:${identity.id}`)));
  return { signature: `v1.${encode(digest)}`, login: identity.login };
}

export function sameOwner(left: RegistryOwner, right: RegistryOwner) {
  const encoder = new TextEncoder();
  const a = encoder.encode(left.signature);
  const b = encoder.encode(right.signature);
  let difference = a.length ^ b.length;
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) difference |= (a[index] ?? 0) ^ (b[index] ?? 0);
  return difference === 0;
}

function encode(value: Uint8Array) {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
