import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { readFile } from "node:fs/promises";
import { resolve, sep } from "node:path";

const registryRoot = resolve(import.meta.dirname, "../repository");

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
      },
    },
  ],
  server: {
    fs: { allow: [resolve(import.meta.dirname, "../..")] },
    port: 5173,
  },
});
