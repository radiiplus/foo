import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { resolve, sep } from "node:path";

const fooRoot = resolve(import.meta.dirname, "../..");
const siblingRepository = resolve(fooRoot, "..", "foo.registry");
const registryRoot = process.env.REGISTRY_LOCAL_REPOSITORY ??
  (existsSync(resolve(siblingRepository, "indexes", "index.json")) ? siblingRepository : resolve(import.meta.dirname, "../repository"));

export default defineConfig({
  plugins: [
    react(),
    {
      name: "foo-local-registry",
      configureServer(server) {
        server.middlewares.use("/registry-data", async (request, response, next) => {
          const relative = decodeURIComponent((request.url ?? "/").split("?", 1)[0]).replace(/^\/+/, "");
          const target = resolve(registryRoot, relative);
          if (!target.startsWith(`${registryRoot}${sep}`)) return next();
          try {
            response.statusCode = 200;
            response.setHeader("content-type", target.endsWith(".jsonl") ? "application/x-ndjson; charset=utf-8" : "application/json; charset=utf-8");
            response.end(await readFile(target));
          } catch (error) {
            if ((error as NodeJS.ErrnoException).code === "ENOENT") return next();
            next(error as Error);
          }
        });
        server.middlewares.use("/foo-data", async (request, response, next) => {
          const relative = decodeURIComponent((request.url ?? "/").split("?", 1)[0]).replace(/^\/+/, "");
          const target = resolve(fooRoot, relative);
          if (!target.startsWith(`${fooRoot}${sep}`)) return next();
          try {
            response.statusCode = 200;
            response.setHeader("content-type", "application/json; charset=utf-8");
            response.end(await readFile(target));
          } catch (error) {
            if ((error as NodeJS.ErrnoException).code === "ENOENT") return next();
            next(error as Error);
          }
        });
      },
    },
  ],
  server: {
    fs: { allow: [resolve(import.meta.dirname, "../..")] },
    port: 5173,
  },
});
