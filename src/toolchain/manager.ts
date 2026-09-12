import { existsSync, mkdirSync, writeFileSync, readFileSync, readdirSync, chmodSync, createWriteStream, unlinkSync } from "fs";
import { join } from "path";
import { execSync } from "child_process";
import * as https from "https";
import * as os from "os";

const CACHE_DIR = join(os.homedir(), ".tratio", "toolchains");
const PIN_FILE = "tratio.lock";

export interface Info {
  version: string;
  path: string;
}

export function getPin(): string | undefined {
  if (existsSync(PIN_FILE)) {
    const content = readFileSync(PIN_FILE, "utf8");
    const match = content.match(/"zig":\s*"([^"]+)"/);
    return match ? match[1] : undefined;
  }
  return undefined;
}

export function setPin(version: string): void {
  const content = `{ "zig": "${version}" }\n`;
  writeFileSync(PIN_FILE, content);
}

export function detect(version: string): Info | undefined {
  const dir = join(CACHE_DIR, version);
  const exe = process.platform === "win32" ? "zig.exe" : "zig";
  const path = join(dir, exe);
  if (existsSync(path)) {
    return { version, path };
  }
  return undefined;
}

function downloadFile(url: string, dest: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const file = createWriteStream(dest);
    https.get(url, (response) => {
      if (response.statusCode === 302 || response.statusCode === 301) {
        downloadFile(response.headers.location!, dest).then(resolve).catch(reject);
        return;
      }
      if (response.statusCode !== 200) {
        reject(new Error(`Failed to download: ${response.statusCode}`));
        return;
      }
      
      const total = parseInt(response.headers["content-length"] || "0", 10);
      let downloaded = 0;
      
      response.on("data", (chunk) => {
        downloaded += chunk.length;
        if (total > 0) {
          const percent = Math.round((downloaded / total) * 100);
          process.stdout.write(`\r[Toolchain] Downloading: ${percent}%`);
        }
      });
      
      response.pipe(file);
      file.on("finish", () => {
        file.close();
        process.stdout.write("\n");
        resolve();
      });
    }).on("error", (err) => {
      unlinkSync(dest);
      reject(err);
    });
  });
}

export async function install(version: string): Promise<Info> {
  const dir = join(CACHE_DIR, version);
  if (existsSync(dir)) {
    const exeName = process.platform === "win32" ? "zig.exe" : "zig";
    return { version, path: join(dir, exeName) };
  }
  
  mkdirSync(dir, { recursive: true });
  console.log(`[Toolchain] Fetching Zig ${version}...`);
  
  const platform = process.platform === "win32" ? "windows" : 
                   process.platform === "darwin" ? "macos" : "linux";
  const arch = process.arch === "x64" ? "x86_64" : 
               process.arch === "arm64" ? "aarch64" : process.arch;
  
  const ext = platform === "windows" ? "zip" : "tar.xz";
  const filename = `zig-${platform}-${arch}-${version}.${ext}`;
  const url = `https://ziglang.org/download/${version}/${filename}`;
  const archivePath = join(dir, filename);
  
  try {
    await downloadFile(url, archivePath);
    console.log("[Toolchain] Extracting...");
    
    if (platform === "windows") {
      execSync(`tar -xf "${archivePath}" -C "${dir}"`, { stdio: "inherit" });
    } else {
      execSync(`tar -xf "${archivePath}" -C "${dir}" --strip-components=1`, { stdio: "inherit" });
    }
    
    const exeName = process.platform === "win32" ? "zig.exe" : "zig";
    const exePath = join(dir, exeName);
    
    if (process.platform !== "win32") {
      chmodSync(exePath, 0o755);
    }
    
    console.log(`[Toolchain] Zig ${version} installed successfully.`);
    return { version, path: exePath };
  } catch (err) {
    throw new Error(`Failed to install Zig ${version}: ${err instanceof Error ? err.message : String(err)}`);
  }
}

export function list(): string[] {
  if (!existsSync(CACHE_DIR)) return [];
  return readdirSync(CACHE_DIR);
}