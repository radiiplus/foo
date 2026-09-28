import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "../../..");
const target = resolve(import.meta.dirname, "../public/llm.txt");
const folders = ["docs", "specs"];
const clean = (content) => content.replace(/[ \t]+$/gm, "").trim();
const parts = [
  "# FOO Language Documentation",
  "",
  "Canonical site: https://fooregistry.web.app/docs/overview",
  "Source: https://github.com/radiiplus/foo",
  "",
  "This file contains the complete FOO book, normative specifications, and changelog. Sections marked Design are proposals, not accepted syntax.",
];

for (const folder of folders) {
  const files = readdirSync(resolve(root, folder))
    .filter((file) => file.endsWith(".md"))
    .sort((left, right) => {
      if (left === "README.md") return -1;
      if (right === "README.md") return 1;
      return left.localeCompare(right);
    });
  for (const file of files) {
    parts.push("", `--- SOURCE: ${folder}/${file} ---`, "",
      clean(readFileSync(resolve(root, folder, file), "utf8")));
  }
}

parts.push("", "--- SOURCE: CHANGELOG.md ---", "",
  clean(readFileSync(resolve(root, "CHANGELOG.md"), "utf8")));

writeFileSync(target, `${parts.join("\n")}\n`, "utf8");
