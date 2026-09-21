const https = require("node:https");
const fs = require("node:fs");
const server = https.createServer({ key: fs.readFileSync(process.argv[2]), cert: fs.readFileSync(process.argv[3]) }, (_, response) => {
  response.end("verified TLS");
});
server.on("tlsClientError", () => {});
server.listen(0, "127.0.0.1", () => process.send(server.address().port));
process.on("disconnect", () => server.closeAllConnections() || server.close());
