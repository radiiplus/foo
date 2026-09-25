import { requiredSetting } from "./environment.ts";

const encoder = new TextEncoder();
const challengePattern = /^[A-Za-z0-9_-]{43}$/;
const verifierPattern = /^[A-Za-z0-9._~-]{43,128}$/;

type OAuthState = {
  redirect: string;
  challenge: string;
  expires: number;
  nonce: string;
};

export class OAuthError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

export async function beginOAuth(request: Request) {
  const requestUrl = new URL(request.url);
  const redirect = callback(requestUrl.searchParams.get("redirect_uri"));
  const challenge = requestUrl.searchParams.get("code_challenge") ?? "";
  if (!challengePattern.test(challenge)) throw new OAuthError("Invalid PKCE challenge", 400);
  const secret = stateSecret();
  const state = await seal(JSON.stringify({
    redirect,
    challenge,
    expires: Date.now() + 600_000,
    nonce: random(24),
  } satisfies OAuthState), secret);
  const url = new URL("https://github.com/login/oauth/authorize");
  url.searchParams.set("client_id", requiredSetting("GITHUB_CLIENT_ID"));
  url.searchParams.set("redirect_uri", redirect);
  url.searchParams.set("state", state);
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");
  return Response.redirect(url, 302);
}

export async function exchangeOAuth(request: Request, requestFetch: typeof fetch = fetch) {
  let input: Record<string, unknown>;
  try {
    const value = await request.json();
    if (!object(value)) throw new Error();
    input = value;
  } catch {
    throw new OAuthError("Invalid OAuth exchange", 400);
  }
  if (Object.keys(input).some((key) => !["code", "state", "verifier", "redirect_uri"].includes(key))) {
    throw new OAuthError("Invalid OAuth exchange fields", 400);
  }
  const code = text(input.code);
  const state = text(input.state);
  const verifier = text(input.verifier);
  const redirect = callback(text(input.redirect_uri));
  if (!code || !state || !verifier || !verifierPattern.test(verifier)) throw new OAuthError("Invalid OAuth exchange", 400);

  let saved: OAuthState;
  try {
    saved = JSON.parse(await open(state, stateSecret()));
  } catch {
    throw new OAuthError("Invalid OAuth state", 400);
  }
  const challenge = await digest(verifier);
  if (saved.expires < Date.now() || !constant(saved.redirect, redirect) || !constant(saved.challenge, challenge)) {
    throw new OAuthError("Expired or mismatched OAuth state", 400);
  }

  const response = await requestFetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: requiredSetting("GITHUB_CLIENT_ID"),
      client_secret: requiredSetting("GITHUB_CLIENT_SECRET"),
      code,
      redirect_uri: redirect,
      code_verifier: verifier,
    }),
  });
  if (!response.ok) throw new OAuthError("GitHub OAuth exchange failed", 502);
  const token = await response.json() as { access_token?: unknown; token_type?: unknown; expires_in?: unknown };
  if (typeof token.access_token !== "string" || token.access_token.length === 0) throw new OAuthError("GitHub OAuth returned no token", 502);
  return Response.json({
    access_token: token.access_token,
    token_type: typeof token.token_type === "string" ? token.token_type : "bearer",
    ...(typeof token.expires_in === "number" ? { expires_in: token.expires_in } : {}),
  }, { headers: { "access-control-allow-origin": "*" } });
}

export async function beginDevice(requestFetch: typeof fetch = fetch) {
  const response = await requestFetch("https://github.com/login/device/code", {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: requiredSetting("GITHUB_CLIENT_ID") }),
  });
  if (!response.ok) throw new OAuthError("GitHub device authorization failed", 502);
  const value = await response.json() as Record<string, unknown>;
  const deviceCode = text(value.device_code);
  const userCode = text(value.user_code);
  const verificationUri = text(value.verification_uri);
  if (!deviceCode || !userCode || !verificationUri) throw new OAuthError("GitHub device authorization returned an invalid response", 502);
  return oauthJson({
    device_code: deviceCode,
    user_code: userCode,
    verification_uri: verificationUri,
    expires_in: positive(value.expires_in, 900),
    interval: positive(value.interval, 5),
  });
}

export async function exchangeDevice(request: Request, requestFetch: typeof fetch = fetch) {
  let input: Record<string, unknown>;
  try {
    const value = await request.json();
    if (!object(value) || Object.keys(value).some((key) => key !== "device_code")) throw new Error();
    input = value;
  } catch {
    throw new OAuthError("Invalid device exchange", 400);
  }
  const deviceCode = text(input.device_code);
  if (!deviceCode) throw new OAuthError("Invalid device exchange", 400);
  const response = await requestFetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: requiredSetting("GITHUB_CLIENT_ID"),
      device_code: deviceCode,
      grant_type: "urn:ietf:params:oauth:grant-type:device_code",
    }),
  });
  if (!response.ok) throw new OAuthError("GitHub device token exchange failed", 502);
  const value = await response.json() as Record<string, unknown>;
  const error = text(value.error);
  if (error) {
    const pending = error === "authorization_pending" || error === "slow_down";
    return oauthJson({ error, description: text(value.error_description) }, pending ? 202 : 400);
  }
  const accessToken = text(value.access_token);
  if (!accessToken) throw new OAuthError("GitHub device token exchange returned no token", 502);
  return oauthJson({
    access_token: accessToken,
    token_type: text(value.token_type) || "bearer",
    ...(typeof value.scope === "string" ? { scope: value.scope } : {}),
  });
}

function callback(value: string | null) {
  if (!value) throw new OAuthError("OAuth callback is required", 400);
  let normalized: string;
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password || url.hash || url.search) throw new Error();
    normalized = url.toString();
  } catch {
    throw new OAuthError("Invalid OAuth callback", 400);
  }
  const allowed = requiredSetting("GITHUB_OAUTH_CALLBACKS").split(",").map((item) => {
    try {
      return new URL(item.trim()).toString();
    } catch {
      return "";
    }
  });
  if (!allowed.includes(normalized)) throw new OAuthError("OAuth callback is not allowed", 400);
  return normalized;
}

function stateSecret() {
  const secret = requiredSetting("OAUTH_STATE_SECRET");
  if (secret.length < 32) throw new OAuthError("OAUTH_STATE_SECRET must contain at least 32 characters", 503);
  return secret;
}

async function seal(value: string, secret: string) {
  const body = encode(encoder.encode(value));
  return `${body}.${encode(await signature(body, secret))}`;
}

async function open(value: string, secret: string) {
  const [body, supplied, extra] = value.split(".");
  if (!body || !supplied || extra || !constant(encode(await signature(body, secret)), supplied)) throw new Error("Invalid signature");
  return new TextDecoder().decode(decode(body));
}

async function signature(value: string, secret: string) {
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(value)));
}

async function digest(value: string) {
  return encode(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(value))));
}

function random(size: number) {
  return encode(crypto.getRandomValues(new Uint8Array(size)));
}

function constant(left: string, right: string) {
  const a = encoder.encode(left);
  const b = encoder.encode(right);
  let result = a.length ^ b.length;
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) result |= (a[index] ?? 0) ^ (b[index] ?? 0);
  return result === 0;
}

function encode(value: Uint8Array) {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function decode(value: string) {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
}

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function text(value: unknown) {
  return typeof value === "string" ? value : "";
}

function positive(value: unknown, fallback: number) {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : fallback;
}

function oauthJson(body: unknown, status = 200) {
  return Response.json(body, { status, headers: { "access-control-allow-origin": "*" } });
}
