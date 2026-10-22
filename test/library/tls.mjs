import { spawn, spawnSync as invoke } from "node:child_process";
import { existsSync as exists, readFileSync as read, rmSync as remove, mkdirSync as mkdir, writeFileSync as write } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { createServer } from "node:tls";
import { fileURLToPath as filename } from "node:url";
import { environment, temporary } from '../location.mjs';

const root = resolve(dirname(filename(import.meta.url)), "../..");
const selected = process.argv.find(argument => argument.startsWith("--backend="))?.slice(10);
if (selected && selected !== "qbe")
  throw new Error("TLS tests run only on QBE");
const backends = ["qbe"];
const mode = process.argv.find(argument => argument.startsWith('--modes='))?.slice(8);
if (mode && !['dev', 'release'].includes(mode)) throw Error('TLS mode must be dev or release');
const modes = mode ? [mode] : ["dev", "release"];
const expected = backends.length * modes.length * 2;
const count = [...read(join(root,"test/library/tls.iv"),"utf8").matchAll(/^\s*test\s+"/gm)].length;
const openssl = process.env.FOO_OPENSSL ?? (process.platform === "win32"
  ? "C:/Program Files/Git/mingw64/bin/openssl.exe" : "openssl");
const directory = temporary();
const path=resolve(process.env.FOO_TLS_REPORT || join(directory, 'report.json'));
mkdir(dirname(path),{recursive:true});
const observations=[];
function report(complete=false){write(path,JSON.stringify({format:"foo.tls-tests.v1",complete,passed:complete&&observations.length===expected&&observations.every(r=>r.passed),expectedObservations:expected,observations:observations.length,executedTests:observations.reduce((n,r)=>n+r.tests.filter(t=>t.executed).length,0),results:observations},null,2)+"\n");}
report();
const cert = join(directory, "cert.pem");
const key = join(directory, "key.pem");

try {
  const created = invoke(openssl, ["req", "-x509", "-newkey", "rsa:2048",
    "-nodes", "-keyout", key, "-out", cert, "-subj", "/CN=localhost",
    "-addext", "subjectAltName=DNS:localhost", "-days", "1"],
    { encoding: "utf8", windowsHide: true });
  if (created.status !== 0) throw new Error(created.stderr || created.error?.message);
  const server = createServer({ cert: read(cert), key: read(key) }, socket => {
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
    const env = environment(directory, { ...process.env, FOO_TLS_TEST: "1",
      SSL_CERT_FILE: cert, FOO_TLS_TEST_PORT: String(server.address().port) });
    if (process.platform === "win32" && !env.FOO_TLS_LIBRARY) {
      const library = join(dirname(openssl), "libssl-3-x64.dll");
      if (exists(library)) env.FOO_TLS_LIBRARY = library;
    }
    for (const mode of modes) for (const [backend, trusted] of [true, false].flatMap(trusted =>
      backends.map(backend => [backend, trusted]))) {
      if (trusted) {
        env.FOO_TLS_TEST = "1";
        env.SSL_CERT_FILE = cert;
        delete env.FOO_TLS_REJECT;
      } else {
        env.FOO_TLS_REJECT = "1";
        delete env.FOO_TLS_TEST;
        delete env.SSL_CERT_FILE;
      }
      const response = await new Promise((done, fail) => {
        const child = spawn(process.execPath,
          [join(root, "bin", "foo.mjs"), "test", "test/library/tls.iv", "--backend", backend,"--mode",mode,"--json"],
          { cwd: root, env, stdio: ["ignore","pipe","pipe"], windowsHide: true, detached: process.platform !== "win32" });
        let stdout="",stderr="";
        const timer=setTimeout(()=>{if(process.platform === "win32")invoke("taskkill",["/pid",String(child.pid),"/t","/f"],{windowsHide:true,stdio:"ignore"});else try{process.kill(-child.pid,"SIGKILL");}catch{} fail(Error("TLS test timeout"));},Number(process.env.FOO_TEST_TIMEOUT||600000));
        child.stdout.on("data",b=>stdout+=b);child.stderr.on("data",b=>stderr+=b);
        child.once("error",e=>{clearTimeout(timer);fail(e);});
        child.once("close",code=>{clearTimeout(timer);done({code,stdout,stderr});});
      });
      const tests=response.stdout.split(/\r?\n/).filter(Boolean).map(line=>JSON.parse(line)).filter(e=>e.event==="test-result");
      observations.push({backend,mode,trusted,exitCode:response.code,tests,passed:response.code===0&&tests.length===count&&tests.every(t=>t.passed&&t.executed),stderr:response.stderr});
      report();
      console.log(`${observations.at(-1).passed?"PASS":"FAIL"} TLS/${backend}/${mode}/${trusted?"trusted":"reject"}: ${tests.filter(t=>t.executed).length} executed`);
    }
  } finally {
    await new Promise(done => server.close(done));
  }
  report(true);
  if(!observations.every(r=>r.passed))process.exitCode=1;
} finally {
  remove(cert, { force: true });
  remove(key, { force: true });
}
