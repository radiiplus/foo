import { handleRequest } from "../supabase/functions/_shared/handler.ts";

Deno.test("health endpoint returns the service status", async () => {
  const response = await handleRequest(new Request("http://localhost/functions/v1/registry/health"));
  const body = await response.json();
  if (response.status !== 200 || body.service !== "foo" || body.status !== "ok") throw new Error(`Unexpected response: ${JSON.stringify(body)}`);
});

Deno.test("preflight requests include CORS headers", async () => {
  const response = await handleRequest(new Request("http://localhost/functions/v1/registry/publish", { method: "OPTIONS" }));
  if (response.status !== 204 || response.headers.get("access-control-allow-origin") !== "*") throw new Error("Expected a successful CORS preflight response");
});

Deno.test("discovery routes are delegated to the Git catalog reader", async () => {
  let selected = "";
  const response = await handleRequest(
    new Request("http://localhost/functions/v1/registry/search?q=http"),
    undefined,
    undefined,
    async (_request, route) => {
      selected = route;
      return Response.json({ schema: "foo.search/v1", packages: [] });
    },
  );
  if (response.status !== 200 || selected !== "/search") throw new Error(`Unexpected discovery response: ${response.status}`);
});
