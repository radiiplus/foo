import { existsSync, readdirSync } from 'node:fs';
import { delimiter, join, resolve } from 'node:path';

export function find(name, override = '') {
  if (override) return existsSync(override) ? resolve(override) : override;
  for (const directory of (process.env.PATH || '').split(delimiter)) {
    const file = join(directory, name);
    if (existsSync(file)) return file;
  }
  const programs = process.env['ProgramFiles(x86)'] || 'C:/Program Files (x86)';
  if (name === 'rc.exe') {
    const bin = join(programs, 'Windows Kits', '10', 'bin');
    if (existsSync(bin)) for (const version of readdirSync(bin).sort().reverse()) {
      const file = join(bin, version, 'x64', name);
      if (existsSync(file)) return file;
    }
  }
  if (name === 'dumpbin.exe') {
    const direct = join(process.env.VCToolsInstallDir || '', 'bin', 'HostX64', 'x64', name);
    if (process.env.VCToolsInstallDir && existsSync(direct)) return direct;
    const studio = join(process.env.ProgramFiles || 'C:/Program Files', 'Microsoft Visual Studio');
    if (existsSync(studio)) for (const year of readdirSync(studio).sort().reverse()) {
      for (const edition of readdirSync(join(studio, year))) {
        const tools = join(studio, year, edition, 'VC', 'Tools', 'MSVC');
        if (!existsSync(tools)) continue;
        for (const version of readdirSync(tools).sort().reverse()) {
          const file = join(tools, version, 'bin', 'HostX64', 'x64', name);
          if (existsSync(file)) return file;
        }
      }
    }
  }
  throw Error(`Required Windows tool is unavailable: ${name}`);
}
