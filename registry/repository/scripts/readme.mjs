import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const token = process.env.GITHUB_TOKEN;
const repository = process.env.GITHUB_REPOSITORY ?? "radiiplus/foo.registry";
const branch = process.env.GITHUB_BRANCH ?? "main";
if (!token) throw new Error("GITHUB_TOKEN is required");
if (!/^[^/]+\/[^/]+$/.test(repository)) throw new Error("GITHUB_REPOSITORY must be owner/name");

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const content = await readFile(join(root, "README.md"));
const api = `https://api.github.com/repos/${repository}`;
const headers = {
  accept: "application/vnd.github+json",
  authorization: `Bearer ${token}`,
  "content-type": "application/json",
  "user-agent": "foo-registry-readme",
  "x-github-api-version": "2026-03-10",
};
const current = await fetch(`${api}/contents/README.md?ref=${encodeURIComponent(branch)}`, { headers });
if (!current.ok) throw new Error(`Unable to read registry README: ${current.status}`);
const existing = await current.json();
const response = await fetch(`${api}/contents/README.md`, {
  method: "PUT",
  headers,
  body: JSON.stringify({
    message: "refresh registry readme",
    content: content.toString("base64"),
    sha: existing.sha,
    branch,
  }),
});
if (!response.ok) {
  const error = await response.json().catch(() => ({}));
  throw new Error(`Unable to update registry README: ${error.message ?? response.status}`);
}
const result = await response.json();
console.log(`updated ${repository} README at ${result.commit.sha}`);
