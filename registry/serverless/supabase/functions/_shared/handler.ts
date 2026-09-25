import { CatalogError, handleDiscovery, type Discovery } from "./catalog.ts";
import { githubIdentity, IdentityError, type GitHubIdentity } from "./identity.ts";
import { publication, type PackageRecord } from "./manifest.ts";
import { beginDevice, beginOAuth, exchangeDevice, exchangeOAuth, OAuthError } from "./oauth.ts";
import { deprecatePackage, PublishError, publishPackage, type PublishResult } from "./publisher.ts";

const corsHeaders = {
  "access-control-allow-headers": "authorization, content-type",
  "access-control-allow-methods": "GET, POST, OPTIONS",
  "access-control-allow-origin": "*",
};

type Publisher = (record: PackageRecord) => Promise<PublishResult>;
type Identity = (request: Request) => Promise<GitHubIdentity>;
type Deprecator = (name: string, version: string, message: string, owner: GitHubIdentity) => Promise<PublishResult>;

function json(body: unknown, status = 200) {
  return Response.json(body, { status, headers: corsHeaders });
}

export async function handleRequest(
  request: Request,
  publish: Publisher = publishPackage,
  identify: Identity = githubIdentity,
  discover: Discovery = handleDiscovery,
  deprecate: Deprecator = deprecatePackage,
): Promise<Response> {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  const route = getRoute(new URL(request.url).pathname);

  if (request.method === "GET" && route === "/") {
    return json({
      service: "foo",
      version: "v1",
      source: "git",
      endpoints: [
        "GET /search", "GET /package/:name", "GET /category/:category", "GET /tag/:tag", "GET /resolve/:package",
        "POST /auth/device", "POST /auth/device/token", "GET /health", "POST /publish", "POST /deprecate",
      ],
    });
  }
  if (request.method === "GET" && route === "/health") return json({ service: "foo", status: "ok", version: "v1" });

  try {
    if (request.method === "GET" && discoveryRoute(route)) return await discover(request, route);
    if (request.method === "GET" && route === "/auth/github") return await beginOAuth(request);
    if (request.method === "POST" && route === "/auth/exchange") return await exchangeOAuth(request);
    if (request.method === "POST" && route === "/auth/device") return await beginDevice();
    if (request.method === "POST" && route === "/auth/device/token") return await exchangeDevice(request);
    if (request.method === "POST" && route === "/publish") {
      const owner = await identify(request);
      const record = await publication(await request.json() as unknown, owner);
      const result = await publish(record);
      return json({ package: record.name, version: record.version, owner: record.owner.login, ...result }, 201);
    }
    if (request.method === "POST" && route === "/deprecate") {
      const owner = await identify(request);
      const body = await request.json() as { name?: unknown; version?: unknown; message?: unknown };
      if (typeof body.name !== "string" || typeof body.version !== "string" || typeof body.message !== "string") {
        throw new TypeError("name, version, and message are required");
      }
      const result = await deprecate(body.name, body.version, body.message, owner);
      return json({ package: body.name, version: body.version, deprecated: body.message.trim(), ...result });
    }
  } catch (error) {
    if (error instanceof CatalogError || error instanceof PublishError || error instanceof IdentityError || error instanceof OAuthError) return json({ error: error.message }, error.status);
    if (error instanceof SyntaxError || error instanceof TypeError) return json({ error: error.message }, 400);
    console.error(error);
    return json({ error: "Publication failed" }, 500);
  }

  return json({ error: "Not found" }, 404);
}

function discoveryRoute(route: string) {
  return route === "/search" || route.startsWith("/package/") || route.startsWith("/category/") ||
    route.startsWith("/tag/") || route.startsWith("/resolve/");
}

function getRoute(pathname: string) {
  const marker = "/registry";
  const index = pathname.lastIndexOf(marker);
  if (index === -1) return pathname;
  return pathname.slice(index + marker.length) || "/";
}
