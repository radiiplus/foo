import {
  mkdirSync as mkdir,
  readdirSync as list,
  readFileSync as read,
  renameSync as rename,
  writeFileSync as write,
} from "node:fs";
import { dirname, extname, relative, resolve, sep } from "node:path";
import { fileURLToPath as filename } from "node:url";

const root = resolve(dirname(filename(import.meta.url)), "..");
const requested = process.argv[2] ?? ".artifacts/export/codebase.md";

if (requested === "--help" || requested === "-h") {
  console.log("Usage: npm run export-code -- [output.md]");
  process.exit(0);
}

if (process.argv.length > 3) {
  console.error("Usage: npm run export-code -- [output.md]");
  process.exit(1);
}

const destination = resolve(root, requested);
const temporary = `${destination}.tmp`;

const pruned = new Set([
  ".artifacts",
  ".cache",
  ".git",
  ".hg",
  ".next",
  ".nuxt",
  ".parcel-cache",
  ".pnpm-store",
  ".svn",
  ".svelte-kit",
  ".turbo",
  ".venv",
  ".yarn",
  "__pycache__",
  "bin",
  "bower_components",
  "build",
  "coverage",
  "dist",
  "env",
  "node_modules",
  "obj",
  "out",
  "target",
  "vendor",
  "venv",
]);

const omitted = new Set([
  "npm-shrinkwrap.json",
  "package-lock.json",
  "pnpm-lock.yaml",
  "yarn.lock",
]);

const extensions = new Set([
  ".astro", ".bash", ".c", ".cc", ".clj", ".cljs", ".cpp", ".cs",
  ".css", ".cts", ".dart", ".ejs", ".ex", ".exs", ".fs", ".fsx",
  ".go", ".graphql", ".h", ".hpp", ".html", ".java", ".js", ".jsx",
  ".kt", ".kts", ".less", ".lua", ".mjs", ".mts", ".php", ".proto",
  ".py", ".r", ".rb", ".rs", ".iv", ".sass", ".scss", ".sh", ".sol",
  ".sql", ".svelte", ".swift", ".toml", ".ts", ".tsx", ".vue", ".xml",
  ".yaml", ".yml", ".zig", ".zsh",
]);

const named = new Set([
  "Dockerfile",
  "Gemfile",
  "Justfile",
  "Makefile",
  "build.gradle",
  "build.gradle.kts",
  "composer.json",
  "deno.json",
  "deno.jsonc",
  "package.json",
  "project.ivc",
  "tsconfig.json",
  "tsconfig.base.json",
]);

const languages = new Map([
  [".bash", "bash"], [".c", "c"], [".cc", "cpp"], [".cpp", "cpp"],
  [".cs", "csharp"], [".css", "css"], [".go", "go"], [".html", "html"],
  [".java", "java"], [".js", "javascript"], [".jsx", "jsx"], [".mjs", "javascript"],
  [".py", "python"], [".rb", "ruby"], [".rs", "rust"], [".sh", "bash"],
  [".ts", "typescript"], [".tsx", "tsx"], [".xml", "xml"], [".yaml", "yaml"],
  [".yml", "yaml"], [".zig", "zig"],
]);

function source(name) {
  return named.has(name) || extensions.has(extname(name).toLowerCase());
}

function collect(directory) {
  const files = [];
  const entries = list(directory, { withFileTypes: true })
    .sort((left, right) => left.name.localeCompare(right.name, "en"));

  for (const entry of entries) {
    const path = resolve(directory, entry.name);

    if (entry.isDirectory()) {
      if (!pruned.has(entry.name)) {
        files.push(...collect(path));
      }
      continue;
    }

    if (
      entry.isFile()
      && path !== destination
      && path !== temporary
      && !omitted.has(entry.name)
      && source(entry.name)
    ) {
      files.push(path);
    }
  }

  return files;
}

function fence(contents) {
  const longest = Math.max(0, ...Array.from(contents.matchAll(/`+/g), match => match[0].length));
  return "`".repeat(Math.max(3, longest + 1));
}

function language(file) {
  const name = file.slice(file.lastIndexOf(sep) + 1);
  if (name === "Dockerfile") return "dockerfile";
  if (name === "Makefile") return "makefile";
  if (extname(name) === ".json") return "json";
  return languages.get(extname(name).toLowerCase()) ?? extname(name).slice(1);
}

const files = collect(root);
const sections = files.map(file => {
  const label = relative(root, file).split(sep).join("/");
  const contents = read(file, "utf8").replace(/\s+$/, "");
  const delimiter = fence(contents);
  return `## \`${label}\`\n\n${delimiter}${language(file)}\n${contents}\n${delimiter}`;
});

const document = [
  "# Codebase Export",
  "",
  `Exported ${files.length} source files.`,
  "",
  ...sections.flatMap(section => [section, ""]),
].join("\n");

mkdir(dirname(destination), { recursive: true });
write(temporary, document, "utf8");
rename(temporary, destination);

console.log(`Exported ${files.length} source files to ${relative(root, destination) || destination}`);
