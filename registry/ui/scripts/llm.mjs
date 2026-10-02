import { copyFileSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "../../..");
const target = resolve(import.meta.dirname, "../public/llm.txt");
const clean = (content) => content.replace(/[ \t]+$/gm, "").trim();
const core = [
  "docs/README.md",
  "docs/start.md",
  "docs/basics.md",
  "docs/types.md",
  "docs/operators.md",
  "docs/flow.md",
  "docs/functions.md",
  "docs/errors.md",
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
  .filter(name => !core.includes(name))
  .sort();
const sources = ["CHANGELOG.md", ...core, ...remaining];
const parts = [
  "# FOO Language Documentation",
  "",
  "Canonical site: https://fooregistry.web.app/docs/overview",
  "Source: https://github.com/radiiplus/foo",
  "",
  "This file contains the complete canonical language, tool, tutorial, and implementation reference for the current compiler.",
  "",
  "Before relying on a language or toolchain behavior, read the Unreleased section and newest release in CHANGELOG.md. They may supersede an older example elsewhere in this file.",
  "",
  "Do not silently reconcile contradictions. If the documentation, standard library declarations, compiler behavior, or C and Zig backends disagree, write an issue-ready observation report for https://github.com/radiiplus/foo/issues. Include a concise title, FOO version or commit when known, platform and backend, expected behavior with its documentation or declaration source, observed behavior, minimal reproduction, exact diagnostics or output, impact, and any verified workaround. Distinguish confirmed behavior from inference. Do not claim that an issue was submitted unless it actually was.",
];

for (const source of sources) {
  parts.push("", `--- SOURCE: ${source} ---`, "",
    clean(readFileSync(resolve(root, source), "utf8")));
}

writeFileSync(target, `${parts.join("\n")}\n`, "utf8");

const data = resolve(import.meta.dirname, "../public/benchmark");
mkdirSync(data, { recursive: true });
copyFileSync(resolve(root, "benchmark/branch-allocator.json"),
  resolve(data, "branch-allocator.json"));
