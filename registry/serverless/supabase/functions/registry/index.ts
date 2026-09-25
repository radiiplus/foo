import { handleRequest } from "../_shared/handler.ts";

Deno.serve((request) => handleRequest(request));
