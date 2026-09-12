import {
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { dirname, extname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const requestedOutput = process.argv[2] ?? "codebase.md";

if (requestedOutput === "--help" || requestedOutput === "-h") {
  console.log("Usage: npm run export-code -- [output.md]");
  process.exit(0);
}

if (process.argv.length > 3) {
  console.error("Usage: npm run export-code -- [output.md]");
  process.exit(1);
}

const outputPath = resolve(projectRoot, requestedOutput);
const temporaryOutputPath = `${outputPath}.tmp`;

const excludedDirectories = new Set([
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

const excludedFiles = new Set([
  "npm-shrinkwrap.json",
  "package-lock.json",
  "pnpm-lock.yaml",
  "yarn.lock",
]);

const sourceExtensions = new Set([
  ".astro", ".bash", ".c", ".cc", ".clj", ".cljs", ".cpp", ".cs",
  ".css", ".cts", ".dart", ".ejs", ".ex", ".exs", ".fs", ".fsx",
  ".go", ".graphql", ".h", ".hpp", ".html", ".java", ".js", ".jsx",
  ".kt", ".kts", ".less", ".lua", ".mjs", ".mts", ".php", ".proto",
  ".py", ".r", ".rb", ".rs", ".rt", ".sass", ".scss", ".sh", ".sol",
  ".sql", ".svelte", ".swift", ".toml", ".ts", ".tsx", ".vue", ".xml",
  ".yaml", ".yml", ".zig", ".zsh",
]);

const namedSourceFiles = new Set([
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
  "project.json",
  "tsconfig.json",
  "tsconfig.base.json",
]);

const languageNames = new Map([
  [".bash", "bash"], [".c", "c"], [".cc", "cpp"], [".cpp", "cpp"],
  [".cs", "csharp"], [".css", "css"], [".go", "go"], [".html", "html"],
  [".java", "java"], [".js", "javascript"], [".jsx", "jsx"], [".mjs", "javascript"],
  [".py", "python"], [".rb", "ruby"], [".rs", "rust"], [".sh", "bash"],
  [".ts", "typescript"], [".tsx", "tsx"], [".xml", "xml"], [".yaml", "yaml"],
  [".yml", "yaml"], [".zig", "zig"],
]);

function isSourceFile(name) {
  return namedSourceFiles.has(name) || sourceExtensions.has(extname(name).toLowerCase());
}

function collectSourceFiles(directory) {
  const files = [];
  const entries = readdirSync(directory, { withFileTypes: true })
    .sort((left, right) => left.name.localeCompare(right.name, "en"));

  for (const entry of entries) {
    const entryPath = resolve(directory, entry.name);

    if (entry.isDirectory()) {
      if (!excludedDirectories.has(entry.name)) {
        files.push(...collectSourceFiles(entryPath));
      }
      continue;
    }

    if (
      entry.isFile()
      && entryPath !== outputPath
      && entryPath !== temporaryOutputPath
      && !excludedFiles.has(entry.name)
      && isSourceFile(entry.name)
    ) {
      files.push(entryPath);
    }
  }

  return files;
}

function markdownFence(contents) {
  const longestRun = Math.max(0, ...Array.from(contents.matchAll(/`+/g), match => match[0].length));
  return "`".repeat(Math.max(3, longestRun + 1));
}

function languageFor(filePath) {
  const name = filePath.slice(filePath.lastIndexOf(sep) + 1);
  if (name === "Dockerfile") return "dockerfile";
  if (name === "Makefile") return "makefile";
  if (extname(name) === ".json") return "json";
  return languageNames.get(extname(name).toLowerCase()) ?? extname(name).slice(1);
}

const files = collectSourceFiles(projectRoot);
const sections = files.map(filePath => {
  const displayPath = relative(projectRoot, filePath).split(sep).join("/");
  const contents = readFileSync(filePath, "utf8").replace(/\s+$/, "");
  const fence = markdownFence(contents);
  return `## \`${displayPath}\`\n\n${fence}${languageFor(filePath)}\n${contents}\n${fence}`;
});

const document = [
  "# Codebase Export",
  "",
  `Exported ${files.length} source files.`,
  "",
  ...sections.flatMap(section => [section, ""]),
].join("\n");

mkdirSync(dirname(outputPath), { recursive: true });
writeFileSync(temporaryOutputPath, document, "utf8");
renameSync(temporaryOutputPath, outputPath);

console.log(`Exported ${files.length} source files to ${relative(projectRoot, outputPath) || outputPath}`);
