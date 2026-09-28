import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "../../..");
const target = resolve(import.meta.dirname, "../public/llm.txt");
const clean = (content) => content.replace(/[ \t]+$/gm, "").trim();
const sources = [
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
const parts = [
  "# FOO Language Documentation",
  "",
  "Canonical site: https://fooregistry.web.app/docs/overview",
  "Source: https://github.com/radiiplus/foo",
  "",
  "This is the compact canonical language and tool reference for the current compiler. It excludes proposals, duplicated specifications, historical reports, and changelog entries. The website contains the longer tutorials.",
];

for (const source of sources) {
  parts.push("", `--- SOURCE: ${source} ---`, "",
    clean(readFileSync(resolve(root, source), "utf8")));
}

writeFileSync(target, `${parts.join("\n")}\n`, "utf8");
