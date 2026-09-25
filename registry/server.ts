import { readFile } from "node:fs/promises";
import { createServer as createNodeServer } from "node:http";
import type { IncomingMessage } from "node:http";
import { dirname, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { handleRequest } from "./serverless/supabase/functions/_shared/handler.ts";
import { handleDiscovery } from "./serverless/supabase/functions/_shared/catalog.ts";

const defaultPort = 54321;
const defaultHost = "127.0.0.1";
const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "repository");

export function createServer() {
  return createNodeServer(async (incoming, outgoing) => {
    try {
      const host = incoming.headers.host ?? `${defaultHost}:${defaultPort}`;
      const url = new URL(incoming.url ?? "/", `http://${host}`);
      const body = await readBody(incoming);
      const request = new Request(url, {
        method: incoming.method,
        headers: incoming.headers as HeadersInit,
        body,
      });
      const response = await handleRequest(request, undefined, undefined,
        (discoveryRequest, route) => handleDiscovery(discoveryRequest, route, repositoryFetch));

      outgoing.statusCode = response.status;
      response.headers.forEach((value, name) => outgoing.setHeader(name, value));
      outgoing.end(Buffer.from(await response.arrayBuffer()));
    } catch (error) {
      console.error(error);
      outgoing.statusCode = 500;
      outgoing.setHeader("content-type", "application/json; charset=utf-8");
      outgoing.end(JSON.stringify({ error: "Internal server error" }));
    }
  });
}

async function repositoryFetch(input: string | URL | Request) {
  const url = new URL(input instanceof Request ? input.url : input);
  const match = decodeURIComponent(url.pathname).match(/\/(indexes|packages)\/(.+)$/);
  if (!match) return new Response("Not found", { status: 404 });
  const target = resolve(repositoryRoot, match[1], match[2]);
  if (!target.startsWith(`${repositoryRoot}${sep}`)) return new Response("Forbidden", { status: 403 });
  try {
    return new Response(await readFile(target), { status: 200, headers: { "content-type": "application/json" } });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return new Response("Not found", { status: 404 });
    throw error;
  }
}

async function readBody(
  incoming: IncomingMessage,
): Promise<ArrayBuffer | undefined> {
  if (incoming.method === "GET" || incoming.method === "HEAD") {
    return undefined;
  }

  const chunks: Uint8Array[] = [];
  for await (const chunk of incoming) {
    chunks.push(typeof chunk === "string" ? Buffer.from(chunk) : chunk);
  }

  if (chunks.length === 0) {
    return undefined;
  }

  const buffered = Buffer.concat(chunks);
  const body = new Uint8Array(buffered.byteLength);
  body.set(buffered);
  return body.buffer;
}

function isMainModule() {
  const entrypoint = process.argv[1];
  return entrypoint !== undefined && import.meta.url === pathToFileURL(entrypoint).href;
}

if (isMainModule()) {
  const port = Number.parseInt(process.env.PORT ?? String(defaultPort), 10);
  const host = process.env.HOST ?? defaultHost;
  const server = createServer();

  server.listen(port, host, () => {
    console.log(`Temporary registry API listening on http://${host}:${port}`);
  });
}
