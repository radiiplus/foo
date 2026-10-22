import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "../../..");
const target = resolve(import.meta.dirname, "../public/llm.txt");
const clean = (content) => content.replace(/[ \t]+$/gm, "").trim();
const core = [
  "docs/README.md",
  "docs/start.md",
  "docs/language.md",
  "docs/functions.md",
  "docs/modules.md",
  "docs/projects.md",
  "docs/collections.md",
  "docs/memory.md",
  "docs/library.md",
  "docs/catalog.md",
  "docs/packages.md",
  "docs/testing.md",
  "docs/benchmarking.md",
  "docs/compiler.md",
  "docs/diagnostics.md",
  "docs/platforms.md",
  "docs/status.md",
  "docs/syntax.md",
];
const remaining = readdirSync(resolve(root, "docs"))
  .filter(name => name.endsWith(".md"))
  .map(name => `docs/${name}`)
  .filter(name => !core.includes(name) &&
    name !== "docs/POLICY.md")
  .sort();
const sources = [...core, ...remaining];
const parts = [
  "# FOO Language Documentation",
  "",
  "Canonical site: https://fooregistry.web.app/docs/overview",
  "Source: https://github.com/radiiplus/foo",
  "",
  "This file contains the complete canonical language, tool, tutorial, and implementation reference for the current compiler.",
  "",
  "Check the current documentation and target qualification before relying on a language or toolchain behavior.",
  "",
  "Do not silently reconcile contradictions. If documentation, standard library declarations, or compiler behavior disagree, write an issue-ready observation report for https://github.com/radiiplus/foo/issues. Include the FOO version or commit, platform and target, expected behavior with its source, observed behavior, minimal reproduction, exact diagnostics or output, impact, and verified workarounds. Distinguish confirmed behavior from inference.",
];

for (const source of sources) {
  parts.push("", `--- SOURCE: ${source} ---`, "",
    clean(readFileSync(resolve(root, source), "utf8")));
}

writeFileSync(target, `${parts.join("\n")}\n`, "utf8");
