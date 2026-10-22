import { existsSync as exists, readdirSync as entries } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

export function find({ environment = process.env, profile = environment.USERPROFILE || homedir(), platform = process.platform } = {}) {
  const executable = platform === 'win32' ? 'nim.exe' : 'nim';
  const candidates = [environment.NIM_BIN];
  const directory = join(profile, '.choosenim', 'toolchains');
  if (exists(directory)) {
    for (const version of entries(directory).sort().reverse())
      candidates.push(join(directory, version, 'bin', executable));
  }
  // Keep PATH resolution as the fallback. A selected NIM_BIN is never executed
  // during discovery (failure-injection runners deliberately supply Node).
  return candidates.find(candidate => candidate && exists(candidate)) || executable;
}
