import { resolve } from 'node:path';

// One parser for release, native, and benchmark tools. Absence stays distinct
// from an invalid empty value; both --name=value and --name value are supported.
export function value(name, args = process.argv.slice(2)) {
  const inline = args.find(argument => argument.startsWith(name + '='));
  const index = args.indexOf(name);
  const result = inline === undefined ? (index < 0 ? undefined : args[index + 1]) : inline.slice(name.length + 1);
  if (result === undefined && index < 0) return '';
  if (!result || result.startsWith('--')) throw Error(`${name} requires a value`);
  return result;
}

export function option(name, args = process.argv.slice(2)) {
  const result = value(name, args);
  return result ? resolve(result) : '';
}
