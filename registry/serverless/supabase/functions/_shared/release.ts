import type { PackageRecord } from "./manifest.ts";

export function releaseFiles(record: PackageRecord) {
  const root = `packages/${record.name}/${record.version}`;
  const files = new Map<string, string>();
  files.set(`${root}/README.md`, `${record.readme.join("\n")}\n`);
  for (const file of record.source.files) files.set(`${root}/source/${file.path}`, file.content);
  return files;
}
