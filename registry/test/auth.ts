import assert from "node:assert/strict";
import { after, before, test } from "node:test";

import { githubIdentity, registryOwner, sameOwner } from "../serverless/supabase/functions/_shared/identity.ts";
import { beginDevice, beginOAuth, exchangeDevice, exchangeOAuth } from "../serverless/supabase/functions/_shared/oauth.ts";

const names = ["GITHUB_CLIENT_ID", "GITHUB_CLIENT_SECRET", "GITHUB_OAUTH_CALLBACKS", "OAUTH_STATE_SECRET"] as const;
const saved = new Map(names.map((name) => [name, process.env[name]]));

before(() => {
  process.env.GITHUB_CLIENT_ID = "client-id";
  process.env.GITHUB_CLIENT_SECRET = "client-secret";
  process.env.GITHUB_OAUTH_CALLBACKS = "https://foo.web.app/auth/callback";
  process.env.OAUTH_STATE_SECRET = "a-long-test-secret-that-is-never-deployed";
});

test("derives a stable opaque ownership signature", async () => {
  const secret = "test-ownership-secret-with-at-least-32-characters";
  const first = await registryOwner({ id: 152736140, login: "radiiplus" }, secret);
  const renamed = await registryOwner({ id: 152736140, login: "new-login" }, secret);
  const other = await registryOwner({ id: 99, login: "radiiplus" }, secret);
  assert.match(first.signature, /^v1\.[A-Za-z0-9_-]{43}$/);
  assert.equal(first.signature.includes("152736140"), false);
  assert.equal(first.signature, renamed.signature);
  assert.equal(sameOwner(first, renamed), true);
  assert.equal(sameOwner(first, other), false);
});

after(() => {
  for (const [name, value] of saved) {
    if (value === undefined) delete process.env[name];
    else process.env[name] = value;
  }
});

test("validates a bearer token against GitHub and returns the stable identity", async () => {
  const identity = await githubIdentity(new Request("http://localhost/publish", {
    headers: { authorization: "Bearer github-token" },
  }), async (input, init) => {
    assert.equal(input, "https://api.github.com/user");
    assert.equal(new Headers(init?.headers).get("authorization"), "Bearer github-token");
    return Response.json({ id: 152736140, login: "radiiplus" });
  });
  assert.deepEqual(identity, { id: 152736140, login: "radiiplus" });
});

test("completes a stateless OAuth flow with signed state and PKCE", async () => {
  const verifier = "test-verifier-that-is-long-enough-for-pkce-1234567890";
  const codeChallenge = await challenge(verifier);
  const redirect = "https://foo.web.app/auth/callback";
  const startUrl = new URL("https://api.example/functions/v1/registry/auth/github");
  startUrl.searchParams.set("redirect_uri", redirect);
  startUrl.searchParams.set("code_challenge", codeChallenge);
  const start = await beginOAuth(new Request(startUrl));
  assert.equal(start.status, 302);
  const location = new URL(start.headers.get("location")!);
  assert.equal(location.origin, "https://github.com");
  assert.equal(location.searchParams.get("redirect_uri"), redirect);
  assert.equal(location.searchParams.get("code_challenge_method"), "S256");
  assert.equal(location.searchParams.get("code_challenge"), codeChallenge);

  const response = await exchangeOAuth(new Request("https://api.example/functions/v1/registry/auth/exchange", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      code: "temporary-code",
      state: location.searchParams.get("state"),
      verifier,
      redirect_uri: redirect,
    }),
  }), async (input, init) => {
    assert.equal(input, "https://github.com/login/oauth/access_token");
    const body = new URLSearchParams(String(init?.body));
    assert.equal(body.get("client_secret"), "client-secret");
    assert.equal(body.get("code_verifier"), verifier);
    assert.equal(body.get("redirect_uri"), redirect);
    return Response.json({ access_token: "github-access-token", token_type: "bearer", expires_in: 28_800 });
  });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { access_token: "github-access-token", token_type: "bearer", expires_in: 28_800 });
});

test("rejects OAuth callbacks outside the Firebase allowlist", async () => {
  const url = new URL("https://api.example/functions/v1/registry/auth/github");
  url.searchParams.set("redirect_uri", "https://attacker.example/auth/callback");
  url.searchParams.set("code_challenge", "a".repeat(43));
  await assert.rejects(() => beginOAuth(new Request(url)), /not allowed/);
});

test("starts and completes the GitHub device flow without server-side state", async () => {
  const started = await beginDevice(async (input, init) => {
    assert.equal(input, "https://github.com/login/device/code");
    assert.equal(new URLSearchParams(String(init?.body)).get("client_id"), "client-id");
    return Response.json({
      device_code: "device-code",
      user_code: "ABCD-1234",
      verification_uri: "https://github.com/login/device",
      expires_in: 900,
      interval: 5,
    });
  });
  assert.equal(started.status, 200);
  assert.equal((await started.json() as { user_code: string }).user_code, "ABCD-1234");

  const pending = await exchangeDevice(deviceRequest(), async () => Response.json({ error: "authorization_pending" }));
  assert.equal(pending.status, 202);
  assert.equal((await pending.json() as { error: string }).error, "authorization_pending");

  const completed = await exchangeDevice(deviceRequest(), async (input, init) => {
    assert.equal(input, "https://github.com/login/oauth/access_token");
    const body = new URLSearchParams(String(init?.body));
    assert.equal(body.get("device_code"), "device-code");
    assert.equal(body.get("grant_type"), "urn:ietf:params:oauth:grant-type:device_code");
    assert.equal(body.has("client_secret"), false);
    return Response.json({ access_token: "device-access-token", token_type: "bearer", scope: "" });
  });
  assert.equal(completed.status, 200);
  assert.equal((await completed.json() as { access_token: string }).access_token, "device-access-token");
});

function deviceRequest() {
  return new Request("https://api.example/functions/v1/registry/auth/device/token", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ device_code: "device-code" }),
  });
}

async function challenge(verifier: string) {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
