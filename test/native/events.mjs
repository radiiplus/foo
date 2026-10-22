// Only new, attributed completions count as progress; output is not a heartbeat.
export function progress(identity, modules, completed) {
  const cases = new Set();
  return line => {
    const fields = line.split('|');
    if (!['FOO_NATIVE_MODULE', 'FOO_NATIVE_CASE'].includes(fields[0]) || fields[1] !== identity) return false;
    const module = fields[2];
    if (!modules.includes(module)) throw Error('Unknown progress module');
    if (fields[0] === 'FOO_NATIVE_MODULE') {
      if (fields.length !== 3 || completed.has(module)) throw Error('Invalid or duplicate module completion');
      completed.add(module);
    } else {
      const name = fields[3];
      const key = `${module}|${name}`;
      if (fields.length !== 4 || !name || cases.has(key) || completed.has(module) || cases.size >= 4096)
        throw Error('Invalid or duplicate case completion');
      cases.add(key);
    }
    return true;
  };
}
