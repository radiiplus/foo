import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { createServer } from "node:tls";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const openssl = process.env.FOO_OPENSSL ?? (process.platform === "win32"
  ? "C:/Program Files/Git/mingw64/bin/openssl.exe" : "openssl");
const directory = mkdtempSync(join(tmpdir(), "foo-tls-"));
const cert = join(directory, "cert.pem");
const key = join(directory, "key.pem");

try {
  const created = spawnSync(openssl, ["req", "-x509", "-newkey", "rsa:2048",
    "-nodes", "-keyout", key, "-out", cert, "-subj", "/CN=localhost",
    "-addext", "subjectAltName=DNS:localhost", "-days", "1"],
    { encoding: "utf8", windowsHide: true });
  if (created.status !== 0) throw new Error(created.stderr || created.error?.message);
  const server = createServer({ cert: readFileSync(cert), key: readFileSync(key) }, socket => {
    socket.on("error", () => {});
    socket.once("data", data => {
      if (data.toString() !== "ping") socket.destroy(new Error("Unexpected TLS request"));
      else socket.end("pong");
    });
  });
  await new Promise((done, fail) => {
    server.once("error", fail);
    server.listen(0, "127.0.0.1", done);
  });
  try {
    const env = { ...process.env, FOO_TLS_TEST: "1", SSL_CERT_FILE: cert,
      FOO_TLS_TEST_PORT: String(server.address().port) };
    if (process.platform === "win32" && !env.FOO_TLS_LIBRARY) {
      const library = join(dirname(openssl), "libssl-3-x64.dll");
      if (existsSync(library)) env.FOO_TLS_LIBRARY = library;
    }
    for (const [backend, trusted] of [["c", true], ["zig", true],
      ["c", false], ["zig", false]]) {
      if (trusted) {
        env.FOO_TLS_TEST = "1";
        env.SSL_CERT_FILE = cert;
        delete env.FOO_TLS_REJECT;
      } else {
        env.FOO_TLS_REJECT = "1";
        delete env.FOO_TLS_TEST;
        delete env.SSL_CERT_FILE;
      }
      const code = await new Promise((done, fail) => {
        const child = spawn(process.execPath,
          [join(root, "bin", "foo.mjs"), "test", "test/library/tls.iv", "--backend", backend],
          { cwd: root, env, stdio: "inherit", windowsHide: true });
        child.once("error", fail);
        child.once("close", done);
      });
      if (code !== 0) throw new Error(`${backend} ${trusted ? "trusted" : "untrusted"} TLS test failed (${code})`);
    }
  } finally {
    await new Promise(done => server.close(done));
  }
} finally {
  rmSync(directory, { recursive: true, force: true });
}
