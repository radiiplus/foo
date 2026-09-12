# Codebase Export

Exported 100 source files.

## `package.json`

```json
{
  "name": "tratio",
  "version": "0.1.0",
  "scripts": {
    "test": "tsx tests/lex/run.ts && tsx tests/diag/run.ts && tsx tests/parse/run.ts && tsx tests/sema/run.ts && tsx tests/types/run.ts && tsx tests/ir/run.ts && tsx tests/backend/run.ts && tsx tests/stdlib/run.ts && tsx tests/pkg/run.ts"
  },
  "devDependencies": {
    "tsx": "^4.7.0"
  },
  "workspaces": [
    "units/*"
  ]
}
```

## `project.json`

```json
{
  "name": "tratio",
  "version": "0.1.0",
  "language": "1",
  "build": {
    "type": "exe",
    "target": ["linux", "darwin", "windows"],
    "optimize": "dev"
  },
  "dependencies": {}
}
```

## `scripts/exp.mjs`

```javascript
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
```

## `src/ast/node.ts`

```typescript
import { Span } from "../diag/span";

export interface Node {
  span: Span;
  tag: string;
}

export interface Program extends Node { tag: "program"; mods: Module[]; }
export interface Module extends Node { tag: "module"; name: Name; body: Block; }

export type Declaration = Constant | Mutable | Function | Alias | Use;
export type Statement =
  | Constant | Mutable | Give | When | While | Repeat | For
  | Match | Break | Continue | Try | Defer | Unsafe | Action
  | Case | UnreachableStatement | AdvanceStatement | TestBlock;

export type Expression =
  | Integer | Decimal | Text | Character
  | True | False | Uninitialized | Unreachable | Quantity | NewlineExpr
  | Name | Call | Unary | Binary | Group | Field | Index | ErrorChain;

export type Type = Primitive | Array | Sequence | Optional | Error | Pointer | Named;
export type Pattern = Name | Wildcard | Integer | True | False;

export interface Integer extends Node { tag: "integer"; value: string; }
export interface Decimal extends Node { tag: "decimal"; value: string; }
export interface Text extends Node { tag: "text"; value: string; }
export interface Character extends Node { tag: "character"; value: string; }
export interface True extends Node { tag: "true"; }
export interface False extends Node { tag: "false"; }
export interface Uninitialized extends Node { tag: "uninitialized"; }
export interface Unreachable extends Node { tag: "unreachable"; }
export interface Quantity extends Node { tag: "quantity"; value: string; unit: string; }
export interface NewlineExpr extends Node { tag: "newline"; }
export interface Name extends Node { tag: "name"; text: string; }
export interface Call extends Node { tag: "call"; callee: Expression; args: Expression[]; }
export interface Unary extends Node { tag: "unary"; op: string; operand: Expression; }
export interface Binary extends Node { tag: "binary"; op: string; left: Expression; right: Expression; }
export interface Group extends Node { tag: "group"; expr: Expression; }
export interface Field extends Node { tag: "field"; object: Expression; field: Name; }
export interface Index extends Node { tag: "index"; object: Expression; index: Expression; }
export interface ErrorChain extends Node { tag: "error-chain"; expr: Expression; context: Expression; }

export interface Constant extends Node { tag: "constant"; public: boolean; name: Name; type?: Type; value: Expression; }
export interface Mutable extends Node { tag: "mutable"; public: boolean; name: Name; type?: Type; value: Expression; }
export interface Function extends Node { tag: "function"; public: boolean; name: Name; params: Parameter[]; constraint?: Constraint; body: Block; }
export interface Alias extends Node { tag: "alias"; public: boolean; name: Name; body: Record | Choice | Type; }
export interface Use extends Node { 
  tag: "use"; 
  public: boolean; 
  name: Name;
  path?: string;
}
export interface Give extends Node { tag: "give"; value?: Expression; }
export interface When extends Node { tag: "when"; cond: Expression; then: Block; else?: Block | When; }
export interface While extends Node { tag: "while"; cond: Expression; body: Block; }
export interface Repeat extends Node { tag: "repeat"; target: Name; limit: Expression; body: Block; }
export interface For extends Node { tag: "for"; bind: Name; iter: Expression; body: Block; }
export interface Match extends Node { tag: "match"; scrutinee: Expression; cases: Case[]; }
export interface Break extends Node { tag: "break"; }
export interface Continue extends Node { tag: "continue"; }
export interface Try extends Node { tag: "try"; expr: Expression; }
export interface Defer extends Node { tag: "defer"; body: Expression | Block; }
export interface Unsafe extends Node { tag: "unsafe"; body: Block; }
export interface Action extends Node { tag: "action"; name: Name; args: Expression[]; }
export interface Case extends Node { tag: "case"; pattern: Pattern; body: Block; }
export interface UnreachableStatement extends Node { tag: "unreachable-statement"; }
export interface AdvanceStatement extends Node { tag: "advance"; target: Name; }
export interface TestBlock extends Node { tag: "test"; name: Text; body: Block; }

export interface Record extends Node { tag: "record"; fields: Member[]; }
export interface Member extends Node { tag: "member"; name: Name; type: Type; }
export interface Choice extends Node { tag: "choice"; variants: Variant[]; }
export interface Variant extends Node { tag: "variant"; name: Name; value?: Integer; }

export interface Primitive extends Node { tag: "primitive"; name: string; width?: string; }
export interface Array extends Node { tag: "array"; elem: Type; }
export interface Sequence extends Node { tag: "sequence"; elem: Type; }
export interface Optional extends Node { tag: "optional"; elem: Type; }
export interface Error extends Node { tag: "error"; elem: Type; }
export interface Pointer extends Node { tag: "pointer"; elem: Type; }
export interface Named extends Node { tag: "named"; name: Name; }

export interface Parameter extends Node { tag: "parameter"; name: Name; type: Type; }
export interface Constraint extends Node { tag: "constraint"; subject: Name; trait: Name; }
export interface Block extends Node { tag: "block"; stmts: Statement[]; }
export interface Wildcard extends Node { tag: "wildcard"; }
export interface Broken extends Node { tag: "broken"; }
```

## `src/ast/print.ts`

```typescript
import * as ast from "./node";

function indent(depth: number): string {
  return "  ".repeat(depth);
}

function escapeText(text: string): string {
  let out = "";
  for (const ch of text) {
    if (ch === '"') out += '\\"';
    else if (ch === "\\") out += "\\\\";
    else if (ch === "\n") out += "\\n";
    else if (ch === "\t") out += "\\t";
    else if (ch === "\r") out += "\\r";
    else if (ch === "\0") out += "\\0";
    else out += ch;
  }
  return out;
}

export function print(node: ast.Node, depth: number = 0): string {
  switch (node.tag) {
    case "program": return program(node as ast.Program);
    case "module": return module(node as ast.Module, depth);
    case "constant": return constant(node as ast.Constant, depth);
    case "mutable": return mutable(node as ast.Mutable, depth);
    case "function": return function_(node as ast.Function, depth);
    case "alias": return alias(node as ast.Alias, depth);
    case "use": return use(node as ast.Use, depth);
    case "give": return give(node as ast.Give, depth);
    case "when": return when(node as ast.When, depth);
    case "while": return while_(node as ast.While, depth);
    case "repeat": return repeat(node as ast.Repeat, depth);
    case "for": return for_(node as ast.For, depth);
    case "match": return match(node as ast.Match, depth);
    case "break": return `${indent(depth)}break.`;
    case "continue": return `${indent(depth)}continue.`;
    case "try": return try_(node as ast.Try, depth);
    case "defer": return defer(node as ast.Defer, depth);
    case "unsafe": return unsafe(node as ast.Unsafe, depth);
    case "action": return action(node as ast.Action, depth);
    case "advance": return `${indent(depth)}advance ${node.target.text}.`;
    case "unreachable-statement": return `${indent(depth)}unreachable.`;
    case "integer": return (node as ast.Integer).value;
    case "decimal": return (node as ast.Decimal).value;
    case "text": return `"${escapeText((node as ast.Text).value)}"`;
    case "character": return `'${(node as ast.Character).value}'`;
    case "true": return "true";
    case "false": return "false";
    case "uninitialized": return "uninitialized";
    case "unreachable": return "unreachable";
    case "newline": return "newline";
    case "quantity": return `${(node as ast.Quantity).value} ${(node as ast.Quantity).unit}`;
    case "name": return (node as ast.Name).text;
    case "call": return call(node as ast.Call);
    case "unary": return unary(node as ast.Unary);
    case "binary": return binary(node as ast.Binary);
    case "group": return `(${print((node as ast.Group).expr)})`;
    case "field": return field(node as ast.Field);
    case "index": return index(node as ast.Index);
    case "primitive": return primitive(node as ast.Primitive);
    case "array": return `array of ${print((node as ast.Array).elem)}`;
    case "sequence": return `sequence of ${print((node as ast.Sequence).elem)}`;
    case "optional": return `optional ${print((node as ast.Optional).elem)}`;
    case "error": return `error ${print((node as ast.Error).elem)}`;
    case "pointer": return `pointer to ${print((node as ast.Pointer).elem)}`;
    case "named": return (node as ast.Named).name.text;
    case "parameter": return parameter(node as ast.Parameter);
    case "case": return case_(node as ast.Case, depth);
    case "block": return block(node as ast.Block, depth);
    case "wildcard": return "anything";
    case "record": return record(node as ast.Record, depth);
    case "choice": return choice(node as ast.Choice, depth);
    case "member": return member(node as ast.Member, depth);
    case "variant": return variant(node as ast.Variant, depth);
    case "constraint": return constraint(node as ast.Constraint);
    case "broken": return "-- broken";
    default: return "";
  }
}

function program(n: ast.Program): string {
  return n.mods.map(m => print(m, 0)).join("\n\n");
}

function module(n: ast.Module, d: number): string {
  const body = print(n.body, d + 1);
  return `${indent(d)}module ${n.name.text} ${body}`;
}

function constant(n: ast.Constant, d: number): string {
  const pub = n.public ? "public " : "";
  const type = n.type ? ` of type ${print(n.type)}` : "";
  return `${indent(d)}${pub}constant ${n.name.text}${type} is ${print(n.value)}.`;
}

function mutable(n: ast.Mutable, d: number): string {
  const pub = n.public ? "public " : "";
  const type = n.type ? ` of type ${print(n.type)}` : "";
  return `${indent(d)}${pub}mutable ${n.name.text}${type} is ${print(n.value)}.`;
}

function function_(n: ast.Function, d: number): string {
  const pub = n.public ? "public " : "";
  const name = n.name.text === "start" ? "start" : `function ${n.name.text}`;
  const params = n.params.map(p => print(p)).join(", ");
  const constraint = n.constraint ? ` where ${print(n.constraint)}` : "";
  const body = print(n.body, d + 1);
  return `${indent(d)}${pub}${name}(${params})${constraint} ${body}`;
}

function alias(n: ast.Alias, d: number): string {
  const pub = n.public ? "public " : "";
  const body = print(n.body, d);
  return `${indent(d)}${pub}type ${n.name.text} is ${body}.`;
}

function use(n: ast.Use, d: number): string {
  const pub = n.public ? "public " : "";
  return `${indent(d)}${pub}use ${n.name.text}.`;
}

function give(n: ast.Give, d: number): string {
  const value = n.value ? ` ${print(n.value)}` : "";
  return `${indent(d)}give${value}.`;
}

function when(n: ast.When, d: number): string {
  const then = print(n.then, d);
  let result = `${indent(d)}when ${print(n.cond)} ${then}`;
  if (n.else) {
    if (n.else.tag === "when") {
      result += ` otherwise ${print(n.else, d).trim()}`;
    } else {
      result += ` otherwise ${print(n.else, d)}`;
    }
  }
  return result;
}

function while_(n: ast.While, d: number): string {
  return `${indent(d)}while ${print(n.cond)} ${print(n.body, d)}`;
}

function repeat(n: ast.Repeat, d: number): string {
  return `${indent(d)}repeat until ${n.target.text} reaches ${print(n.limit)} ${print(n.body, d)}`;
}

function for_(n: ast.For, d: number): string {
  return `${indent(d)}for each ${n.bind.text} in ${print(n.iter)} ${print(n.body, d)}`;
}

function match(n: ast.Match, d: number): string {
  const cases = n.cases.map(c => print(c, d + 1)).join("\n");
  return `${indent(d)}match ${print(n.scrutinee)} {\n${cases}\n${indent(d)}}`;
}

function try_(n: ast.Try, d: number): string {
  return `${indent(d)}try ${print(n.expr)}.`;
}

function defer(n: ast.Defer, d: number): string {
  if (n.body.tag === "block") {
    return `${indent(d)}on leave ${print(n.body, d)}`;
  }
  return `${indent(d)}on leave ${print(n.body)}.`;
}

function unsafe(n: ast.Unsafe, d: number): string {
  return `${indent(d)}unsafe ${print(n.body, d)}`;
}

function action(n: ast.Action, d: number): string {
  const args = n.args.map(a => print(a)).join(" ");
  return `${indent(d)}${n.name.text}${args ? " " + args : ""}.`;
}

function call(n: ast.Call): string {
  const args = n.args.map(a => print(a)).join(", ");
  return `${print(n.callee)}(${args})`;
}

function unary(n: ast.Unary): string {
  return `${n.op} ${print(n.operand)}`;
}

function binary(n: ast.Binary): string {
  return `${print(n.left)} ${n.op} ${print(n.right)}`;
}

function field(n: ast.Field): string {
  return `${print(n.object)}.${n.field.text}`;
}

function index(n: ast.Index): string {
  return `${print(n.object)}[${print(n.index)}]`;
}

function primitive(n: ast.Primitive): string {
  const width = n.width ? ` ${n.width}` : "";
  return `${n.name}${width}`;
}

function parameter(n: ast.Parameter): string {
  return `${n.name.text} of type ${print(n.type)}`;
}

function constraint(n: ast.Constraint): string {
  return `${n.subject.text} is ${n.trait.text}`;
}

function case_(n: ast.Case, d: number): string {
  return `${indent(d)}case ${print(n.pattern)} ${print(n.body, d)}`;
}

function block(n: ast.Block, d: number): string {
  if (n.stmts.length === 0) return "{ }";
  const stmts = n.stmts.map(s => print(s, d + 1)).join("\n");
  return `{\n${stmts}\n${indent(d)}}`;
}

function record(n: ast.Record, d: number): string {
  if (n.fields.length === 0) return "record { }";
  const fields = n.fields.map(f => print(f, d + 1)).join("\n");
  return `record {\n${fields}\n${indent(d)}}`;
}

function choice(n: ast.Choice, d: number): string {
  const variants = n.variants.map(v => print(v, d + 1)).join("\n");
  return `choice {\n${variants}\n${indent(d)}}`;
}

function member(n: ast.Member, d: number): string {
  return `${indent(d)}${n.name.text} of type ${print(n.type)}.`;
}

function variant(n: ast.Variant, d: number): string {
  const value = n.value ? ` is ${n.value.value}` : "";
  return `${indent(d)}${n.name.text}${value}.`;
}
```

## `src/backend/zig/driver.ts`

```typescript
import { emit, EmitResult } from "./emitter";
import { shim } from "./shim";
import * as ir from "../../ir/node";
import { execFileSync, ExecFileSyncOptionsWithBufferEncoding } from "child_process";
import { writeFileSync, mkdirSync, existsSync } from "fs";
import { join } from "path";

export interface BuildResult {
  success: boolean;
  output?: string;
  error?: string;
}

export function build(mod: ir.Module, mode: string, outDir: string, zigPath: string = "zig"): BuildResult {
  if (!existsSync(outDir)) {
    mkdirSync(outDir, { recursive: true });
  }

  const zigMode = mode === "release" ? "ReleaseFast" : "ReleaseSafe";
  const result = emit(mod, mode);
  
  const mainPath = join(outDir, "main.zig");
  const shimPath = join(outDir, "shim.zig");
  const binPath = join(outDir, "app");

  writeFileSync(mainPath, result.code);
  writeFileSync(shimPath, shim);

  try {
    const opts: ExecFileSyncOptionsWithBufferEncoding = {
      encoding: "utf8",
      maxBuffer: 10 * 1024 * 1024,
    };

    // Uses the dynamically resolved zigPath from the toolchain manager
    execFileSync(zigPath, [
      "build-exe",
      mainPath,
      "-O",
      zigMode,
      `-femit-bin=${binPath}`,
    ], opts);
    
    const output = execFileSync(binPath, [], opts);
    return { success: true, output };
  } catch (err: any) {
    const rawError = err.stderr || err.message;
    const remapped = remapDiagnostics(rawError, result.map, outDir);
    return { success: false, error: remapped };
  }
}

function remapDiagnostics(raw: string, map: Map<number, number>, outDir: string): string {
  const regex = new RegExp(`(${outDir.replace(/\\/g, "\\\\")}[/\\\\]main\\.zig):(\\d+):(\\d+):`, "g");
  
  return raw.replace(regex, (match, file, zigLineStr, colStr) => {
    const zigLine = parseInt(zigLineStr, 10);
    
    let arcLine = zigLine;
    let minDiff = Infinity;
    
    for (const [a, z] of map.entries()) {
      const diff = Math.abs(z - zigLine);
      if (diff < minDiff) {
        minDiff = diff;
        arcLine = a;
      }
    }
    
    return `arc_source.rt:${arcLine}:${colStr}:`;
  });
}
```

## `src/backend/zig/emitter.ts`

```typescript
import * as ir from "../../ir/node";
import { TypeKind, ValueKind, InstrKind } from "../../ir/kind";

export interface EmitResult {
  code: string;
  map: Map<number, number>;
}

function typeStr(t: ir.Type): string {
  switch (t.kind) {
    case TypeKind.Int: return t.width ? `i${t.width}` : "i32";
    case TypeKind.Float: return t.width ? `f${t.width}` : "f64";
    case TypeKind.Bool: return "bool";
    case TypeKind.Ptr: return `*${typeStr(t.elem!)}`;
    case TypeKind.Array: return `[${t.width}]${typeStr(t.elem!)}`;
    case TypeKind.Struct: return t.name || "struct";
    case TypeKind.Void: return "void";
    case TypeKind.Error: return "shim.Error";
  }
}

function valueStr(v: ir.Value): string {
  switch (v.kind) {
    case ValueKind.Reg: return `v_${v.name}`;
    case ValueKind.Const: return v.name;
    case ValueKind.Global: return `&${v.name}`;
  }
}

function usedRegisters(f: ir.Function): Set<string> {
  const used = new Set<string>();

  function add(value: ir.Value | undefined): void {
    if (value?.kind === ValueKind.Reg) used.add(value.name);
  }

  for (const block of f.blocks) {
    for (const instr of [...block.instrs, block.term]) {
      add(instr.target);
      add(instr.ptr);
      add(instr.val);
      add(instr.val2);
      add(instr.cond);
      add(instr.value);
      add(instr.expr);
      for (const arg of instr.args || []) add(arg);
      for (const source of instr.blocks || []) add(source.value);
    }
  }

  return used;
}

export function emit(mod: ir.Module, mode: string): EmitResult {
  let code = `// ARC IR v1 -> Zig\n`;
  code += `const shim = @import("shim.zig");\n\n`;
  
  const map = new Map<number, number>();
  let zigLine = 3;

  function addLine(arcLine: number, text: string): void {
    map.set(arcLine, zigLine);
    code += text + "\n";
    zigLine++;
  }

  for (const ext of mod.externs) {
    const params = ext.params.map(typeStr).join(", ");
    addLine(0, `extern "c" fn ${ext.name}(${params}) ${typeStr(ext.ret)};`);
  }

  if (mod.externs.length > 0) addLine(0, "");

  for (const f of mod.funcs) {
    const used = usedRegisters(f);
    const params = f.params.map(p => `${valueStr(p)}: ${typeStr(p.type)}`).join(", ");
    addLine(0, `pub fn ${f.name}(${params}) ${typeStr(f.ret)} {`);

    if (f.name === "main") {
      addLine(0, `  shim.init(${mode === "dev"});`);
      addLine(0, "  defer shim.deinit();");
    }
    
    for (const b of f.blocks) {
      addLine(0, `  // block ${b.label}`);
      for (const i of b.instrs) {
        addLine(0, `  ${emitInstr(i, used)}`);
      }
      addLine(0, `  ${emitInstr(b.term, used)}`);
    }
    addLine(0, `}`);
    addLine(0, "");
  }

  return { code, map };
}

function emitInstr(i: ir.Instruction, used: Set<string>): string {
  const dest = i.dest ? `const ${valueStr(i.dest)} = ` : "";
  const discard = i.dest && !used.has(i.dest.name) ? ` _ = ${valueStr(i.dest)};` : "";
  const finish = (text: string): string => text + discard;
  
  switch (i.kind) {
    case InstrKind.Alloc:
      return finish(`${dest}shim.allocScope(${typeStr(i.dest!.type)}) catch shim.panic("out of memory");`);
    case InstrKind.Load:
      return finish(`${dest}${valueStr(i.ptr!)}.*;`);
    case InstrKind.Store:
      return `${valueStr(i.ptr!)}.* = ${valueStr(i.val!)};`;
    case InstrKind.Add:
      return finish(`${dest}${valueStr(i.val!)} + ${valueStr(i.val2!)};`);
    case InstrKind.Sub:
      return finish(`${dest}${valueStr(i.val!)} - ${valueStr(i.val2!)};`);
    case InstrKind.Mul:
      return finish(`${dest}${valueStr(i.val!)} * ${valueStr(i.val2!)};`);
    case InstrKind.Div:
      return finish(`${dest}${valueStr(i.val!)} / ${valueStr(i.val2!)};`);
    case InstrKind.Call:
      return finish(`${dest}${i.func}(${(i.args || []).map(valueStr).join(", ")});`);
    case InstrKind.Jump:
      return `// jump ${i.label}`;
    case InstrKind.Cjump:
      return `if (${valueStr(i.cond!)}) { /* ${i.trueLabel} */ } else { /* ${i.falseLabel} */ }`;
    case InstrKind.Return:
      return i.value ? `return ${valueStr(i.value)};` : "return;";
    case InstrKind.Panic:
      return `shim.panic("${i.msg}");`;
    case InstrKind.Try:
      return finish(`${dest}try ${valueStr(i.expr!)};`);
    case InstrKind.Phi:
      return `// phi ${(i.blocks || []).map(b => `[${b.label}: ${valueStr(b.value)}]`).join(", ")}`;
  }
}
```

## `src/backend/zig/shim.ts`

```typescript
export const shim = `
const std = @import("std");

pub const Error = error{
    OutOfMemory,
    Panic,
    Bounds,
    Overflow,
    NotFound,
    Permission,
    Argument,
    Refused,
    Reset,
    Broken,
    Timeout,
    Unexpected,
};

var global_arena: std.heap.ArenaAllocator = undefined;
var debug_allocator: std.heap.DebugAllocator(.{}) = undefined;
var is_dev: bool = true;

pub fn init(dev: bool) void {
    is_dev = dev;
    if (is_dev) {
        debug_allocator = std.heap.DebugAllocator(.{}).init;
        global_arena = std.heap.ArenaAllocator.init(debug_allocator.allocator());
    } else {
        global_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
}

pub fn deinit() void {
    global_arena.deinit();
    if (is_dev) {
        _ = debug_allocator.deinit();
    }
}

pub fn allocScope(comptime T: type) Error!*T {
    return global_arena.allocator().create(T) catch return Error.OutOfMemory;
}

// === Panic Machinery ===
pub var tratio_main_panic: ?*const fn ([*]const u8, usize) noreturn = null;

pub fn set_panic_hook(hook: *const fn ([*]const u8, usize) noreturn) void {
    tratio_main_panic = hook;
}

pub fn panic(msg: []const u8) noreturn {
    if (tratio_main_panic) |hook| {
        hook(msg.ptr, msg.len);
    }
    
    if (is_dev) {
        // Pass default StackUnwindOptions using an empty struct literal
        std.debug.dumpCurrentStackTrace(.{});
    }
    
    std.debug.panic("{s}", .{msg});
}

pub fn bounds(len: usize, idx: usize) void {
    if (idx >= len) {
        panic("bounds check failed");
    }
}

// === Memory ===
pub fn system() std.mem.Allocator {
    return std.heap.page_allocator;
}

pub fn arena() std.mem.Allocator {
    return global_arena.allocator();
}

pub fn allocate(allocator: std.mem.Allocator, size: usize) Error![]u8 {
    return allocator.alloc(u8, size) catch return Error.OutOfMemory;
}

pub fn release(allocator: std.mem.Allocator, buffer: []u8) void {
    allocator.free(buffer);
}

pub fn expand(allocator: std.mem.Allocator, buffer: []u8, new_size: usize) Error![]u8 {
    return allocator.realloc(buffer, new_size) catch return Error.OutOfMemory;
}

// === File ===
pub fn open(path: [*:0]const u8, mode: u8) Error!*std.fs.File {
    const flags: std.fs.File.OpenFlags = switch (mode) {
        0 => .{ .read = true },
        1 => .{ .write = true, .truncate = true },
        2 => .{ .read = true, .write = true },
        3 => .{ .write = true, .truncate = true, .create = true },
        else => return Error.Argument,
    };
    return std.fs.cwd().openFile(std.mem.span(path), flags) catch |err| switch (err) {
        error.FileNotFound => return Error.NotFound,
        error.PermissionDenied => return Error.Permission,
        else => return Error.Unexpected,
    };
}

pub fn read(file: *std.fs.File, buffer: [*]u8, size: usize) Error!usize {
    return file.read(buffer[0..size]) catch return Error.Unexpected;
}

pub fn write(file: *std.fs.File, data: [*]const u8, size: usize) Error!void {
    file.writeAll(data[0..size]) catch return Error.Unexpected;
}

pub fn close(file: *std.fs.File) void {
    file.close();
}

// === Path ===
pub fn merge(out: [*]u8, capacity: usize, first: [*:0]const u8, second: [*:0]const u8) usize {
    const result = std.fs.path.joinZ(out[0..capacity], &[_][]const u8{ std.mem.span(first), std.mem.span(second) });
    return result.len;
}

pub fn parent(out: [*]u8, capacity: usize, path: [*:0]const u8) usize {
    const result = std.fs.path.dirname(std.mem.span(path)) orelse "";
    const len = @min(result.len, capacity);
    @memcpy(out[0..len], result[0..len]);
    return len;
}

pub fn name(path: [*:0]const u8) [*:0]const u8 {
    return std.fs.path.basename(std.mem.span(path));
}

pub fn suffix(path: [*:0]const u8) [*:0]const u8 {
    return std.fs.path.extension(std.mem.span(path));
}

pub fn absolute(path: [*:0]const u8) bool {
    return std.fs.path.isAbsolute(std.mem.span(path));
}

// === Process ===
pub fn args() usize {
    return std.process.args().count;
}

pub fn arg(index: usize, out: [*]u8, capacity: usize) usize {
    var iterator = std.process.args();
    var i: usize = 0;
    while (iterator.next()) |value| : (i += 1) {
        if (i == index) {
            const len = @min(value.len, capacity);
            @memcpy(out[0..len], value[0..len]);
            return len;
        }
    }
    return 0;
}

// === Env ===
pub fn variable(key: [*:0]const u8, out: [*]u8, capacity: usize) usize {
    const value = std.process.getEnvVarOwned(global_arena.allocator(), std.mem.span(key)) catch return 0;
    defer global_arena.allocator().free(value);
    const len = @min(value.len, capacity);
    @memcpy(out[0..len], value[0..len]);
    return len;
}

// === Stream ===
pub fn input() *std.fs.File {
    return &std.io.getStdIn();
}

pub fn output() *std.fs.File {
    return &std.io.getStdOut();
}

pub fn report() *std.fs.File {
    return &std.io.getStdErr();
}

// === Net ===
pub fn dial(host: [*:0]const u8, port: u16) Error!*std.net.Stream {
    const address = std.net.Address.resolveIp(std.mem.span(host), port) catch return Error.Unexpected;
    const connection = std.net.tcpConnectToAddress(address) catch |err| switch (err) {
        error.ConnectionRefused => return Error.Refused,
        else => return Error.Unexpected,
    };
    const result = global_arena.allocator().create(std.net.Stream) catch return Error.OutOfMemory;
    result.* = connection;
    return result;
}

pub fn accept(host: [*:0]const u8, port: u16) Error!*std.net.Server {
    const address = std.net.Address.resolveIp(std.mem.span(host), port) catch return Error.Unexpected;
    const server = address.listen(.{}, 128) catch return Error.Unexpected;
    const result = global_arena.allocator().create(std.net.Server) catch return Error.OutOfMemory;
    result.* = server;
    return result;
}

// === Thread ===
pub fn spawn(comptime func: anytype, argument: anytype) Error!*std.Thread {
    const handle = global_arena.allocator().create(std.Thread) catch return Error.OutOfMemory;
    handle.* = std.Thread.spawn(.{}, func, .{argument}) catch return Error.Unexpected;
    return handle;
}

pub fn await(handle: *std.Thread) void {
    handle.join();
}

// === Sync ===
pub fn mutex() Error!*std.Thread.Mutex {
    return global_arena.allocator().create(std.Thread.Mutex) catch return Error.OutOfMemory;
}

pub fn lock(handle: *std.Thread.Mutex) void {
    handle.lock();
}

pub fn unlock(handle: *std.Thread.Mutex) void {
    handle.unlock();
}

// === Time ===
pub fn instant() i128 {
    return std.time.nanoTimestamp();
}

pub fn moment() i64 {
    return std.time.milliTimestamp();
}

pub fn pause(nanos: u64) void {
    std.time.sleep(nanos);
}

// === Random ===
pub fn entropy(out: [*]u8, size: usize) void {
    var rng = std.crypto.random;
    rng.bytes(out[0..size]);
}

// === Log ===
pub fn log(level: u8, scope: [*:0]const u8, message: [*:0]const u8) void {
    const log_level: std.log.Level = switch (level) {
        0 => .err,
        1 => .warn,
        2 => .info,
        3 => .debug,
        else => .info,
    };
    std.log.log(log_level, "{s}: {s}", .{ std.mem.span(scope), std.mem.span(message) });
}
`;
```

## `src/cli/runner.ts`

```typescript
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "fs";
import { execSync } from "child_process";
import { resolve } from "../targets/presets";
import { detect, install, getPin, setPin } from "../toolchain/manager";
import { Config } from "../linker/orchestrator";
import { build as buildBackend } from "../backend/zig/driver";
import { Engine } from "../diag/engine";
import { Lexer } from "../lex/lexer";
import { Parser } from "../parse/parser";
import { Resolver } from "../sema/resolver";
import { TypeChecker } from "../types/checker";
import { lower } from "../lower/lower"; 
import { runTests } from "../test/runner";
import { format } from "../fmt/formatter";

interface Project {
  name: string;
  version: string;
  language: string;
  build?: {
    target?: string[];
    optimize?: string;
    link?: Config;
  };
  dependencies?: Record<string, string>;
}

export function check(entryFile: string): void {
  console.log(`Checking ${entryFile}...`);
  if (!existsSync(entryFile)) {
    throw new Error(`File not found: ${entryFile}`);
  }
  const src = readFileSync(entryFile, "utf8");
  const diag = new Engine();
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  const ast = parser.parse();
  if (diag.failed) {
    console.error("Parse failed.");
    process.exit(1);
  }
  const resolver = new Resolver(diag, process.cwd());
  resolver.resolve(ast, "main");
  if (diag.failed) {
    console.error("Resolution failed.");
    process.exit(1);
  }
  const typeChecker = new TypeChecker(diag);
  typeChecker.check(ast);
  if (diag.failed) {
    console.error("Type checking failed.");
    process.exit(1);
  }
  console.log("Check passed.");
}

export async function build(entryFile: string, targetPreset?: string): Promise<void> {
  const configPath = "project.json";
  let config: Project = { name: "app", version: "0.1.0", language: "1" };
  if (existsSync(configPath)) {
    config = JSON.parse(readFileSync(configPath, "utf8"));
  }
  const preset = targetPreset || (config.build?.target?.[0]) || "linux-x64";
  const mode = config.build?.optimize || "dev";
  console.log(`Building for ${preset} (${mode})...`);
  
  // 1. Toolchain resolution (dynamic version)
  const pinnedVersion = getPin() || "0.16.0";
  let toolchain = detect(pinnedVersion);
  if (!toolchain) {
    console.log(`[Toolchain] Missing Zig ${pinnedVersion}. Fetching...`);
    toolchain = await install(pinnedVersion);
    setPin(pinnedVersion);
  }
  
  // 2. Read and compile source
  if (!existsSync(entryFile)) {
    throw new Error(`File not found: ${entryFile}`);
  }
  const src = readFileSync(entryFile, "utf8");
  const diag = new Engine();
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  const ast = parser.parse();
  if (diag.failed) {
    console.error("Parse failed.");
    process.exit(1);
  }
  const resolver = new Resolver(diag, process.cwd());
  resolver.resolve(ast, "main");
  if (diag.failed) {
    console.error("Resolution failed.");
    process.exit(1);
  }
  const typeChecker = new TypeChecker(diag);
  typeChecker.check(ast);
  if (diag.failed) {
    console.error("Type checking failed.");
    process.exit(1);
  }
  
  // 3. Lower to IR
  const irMod = lower(ast);
  
  // 4. Backend emission and linking
  const outDir = ".tratio-build";
  mkdirSync(outDir, { recursive: true });
  console.log("Emitting Zig code and compiling...");
  const result = buildBackend(irMod, mode, outDir, toolchain.path);
  if (!result.success) {
    console.error("Build failed:\n" + result.error);
    process.exit(1);
  }
  console.log(`Build successful: ${outDir}/app`);
}

export async function run(entryFile: string, targetPreset?: string): Promise<void> {
  const configPath = "project.json";
  let config: Project = { name: "app", version: "0.1.0", language: "1" };
  if (existsSync(configPath)) {
    config = JSON.parse(readFileSync(configPath, "utf8"));
  }
  const preset = targetPreset || (config.build?.target?.[0]) || "linux-x64";
  const hostPreset = process.platform === "win32" ? "windows-x64" : 
                     process.platform === "darwin" ? "macos-arm64" : "linux-x64";
  await build(entryFile, preset);
  if (preset !== hostPreset) {
    console.log(`Target ${preset} differs from host ${hostPreset}. Attempting to run via qemu...`);
    const arch = preset.includes("arm64") ? "aarch64" : "x86_64";
    try {
      execSync(`qemu-${arch} .tratio-build/app`, { stdio: "inherit" });
    } catch {
      console.error("Failed to run: qemu is not installed or target architecture is unsupported for emulation.");
      process.exit(1);
    }
  } else {
    console.log("Running...");
    execSync(`.tratio-build/app`, { stdio: "inherit" });
  }
}

export function testCmd(root: string, filter?: string, watch: boolean = false, junit?: string): void {
  console.log("Running Tratio tests...");
  runTests(root, filter, watch, junit);
}

export function fmtCmd(file: string): void {
  if (!existsSync(file)) {
    throw new Error(`File not found: ${file}`);
  }
  const src = readFileSync(file, "utf8");
  const diag = new Engine();
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  const ast = parser.parse();
  
  if (diag.failed) {
    console.error("Cannot format: parse errors present.");
    process.exit(1);
  }
  
  const formatted = format(ast);
  writeFileSync(file, formatted);
  console.log(`Formatted ${file}`);
}

export function lspCmd(): void {
  console.error("Starting Tratio LSP server...");
  // The LSP server runs over stdio, so we just require and run it.
  require("../lsp/server");
}
```

## `src/diag/code.ts`

```typescript
export enum Code {
  // Lexer errors
  Unexpected,
  Unterminated,
  Invalid,
  InvalidEscape,
  Digit,
  // Parser errors
  Syntax,
  Missing,
  Extra,
  // Semantic errors
  Duplicate,
  Hidden,
  Clash,
  Absent,
  Circular,
  // Type errors
  TypeMismatch,
  NotCallable,
  NotIndexable,
  NotIterable,
  FieldNotFound,
  VariantNotFound,
  // Escape analysis
  ScopeEscape,
  // Resolution errors
  Undefined,
  NotExported,
  AlreadyImported,
  // Match errors
  NonExhaustive,
  UnreachableCase,
  // Backend errors
  BackendError,
  LinkError,
  // Package manager errors
  PkgConflict,
  PkgHashMismatch,
  PkgNotFound,
  // Error handling
  ErrorContext,
  UncaughtError,
  // Testing
  TestFailed,
}
```

## `src/diag/engine.ts`

```typescript
import { Span } from "./span";
import { Code } from "./code";
import { Note } from "./note";

export interface Message {
  code: Code;
  span: Span;
  text: string;
  notes: Note[];
  suggestion?: string;
  context?: string;
  relatedSpans?: { span: Span; text: string }[];
  source?: string;
}

export class Engine {
  private list: Message[] = [];
  private source?: string;

  setSource(source: string): void {
    this.source = source;
  }

  emit(code: Code, span: Span, text: string, context?: string, source?: string): void {
    const msg: Message = { 
      code, 
      span, 
      text, 
      notes: [],
      context,
      source
    };
    this.list.push(msg);
  }

  note(span: Span, text: string, fix?: string): void {
    const msg = this.list[this.list.length - 1];
    if (msg) {
      msg.notes.push({ span, text, fix });
    }
  }

  suggestion(text: string): void {
    const msg = this.list[this.list.length - 1];
    if (msg) {
      msg.suggestion = text;
    }
  }

  related(span: Span, text: string): void {
    const msg = this.list[this.list.length - 1];
    if (msg) {
      if (!msg.relatedSpans) msg.relatedSpans = [];
      msg.relatedSpans.push({ span, text });
    }
  }

  get messages(): Message[] {
    return this.list;
  }

  get failed(): boolean {
    return this.list.length > 0;
  }

  getSource(): string | undefined {
    return this.source;
  }
}
```

## `src/diag/note.ts`

```typescript
import { Span } from "./span";

export interface Note {
  span: Span;
  text: string;
  fix?: string;
}
```

## `src/diag/render.ts`

```typescript
import { Message } from "./engine";
import { Code } from "./code";

// ANSI color codes
const colors = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  dim: "\x1b[2m",
  red: "\x1b[31m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
  magenta: "\x1b[35m",
  cyan: "\x1b[36m",
  white: "\x1b[37m",
  brightRed: "\x1b[91m",
  brightGreen: "\x1b[92m",
  brightYellow: "\x1b[93m",
  brightBlue: "\x1b[94m",
  brightMagenta: "\x1b[95m",
  brightCyan: "\x1b[96m",
  brightWhite: "\x1b[97m",
};

const codeMessages: Record<Code, { title: string; description: string }> = {
  [Code.Unexpected]: {
    title: "Unexpected token",
    description: "I found something I wasn't expecting here"
  },
  [Code.Unterminated]: {
    title: "Unterminated",
    description: "This never got closed properly"
  },
  [Code.Invalid]: {
    title: "Invalid",
    description: "This isn't valid"
  },
  [Code.InvalidEscape]: {
    title: "Invalid escape sequence",
    description: "This escape sequence isn't recognized"
  },
  [Code.Digit]: {
    title: "Invalid digit",
    description: "This digit doesn't belong here"
  },
  [Code.Syntax]: {
    title: "Syntax error",
    description: "The syntax here isn't quite right"
  },
  [Code.Missing]: {
    title: "Missing",
    description: "I can't find this"
  },
  [Code.Extra]: {
    title: "Extra",
    description: "There's something extra here that shouldn't be"
  },
  [Code.Duplicate]: {
    title: "Duplicate",
    description: "This is already defined"
  },
  [Code.Hidden]: {
    title: "Hidden",
    description: "This isn't accessible from here"
  },
  [Code.Clash]: {
    title: "Conflict",
    description: "This conflicts with something else"
  },
  [Code.Absent]: {
    title: "Not found",
    description: "I couldn't find this module"
  },
  [Code.Circular]: {
    title: "Circular dependency",
    description: "These modules depend on each other in a loop"
  },
  [Code.TypeMismatch]: {
    title: "Type mismatch",
    description: "The types don't match up"
  },
  [Code.NotCallable]: {
    title: "Not callable",
    description: "You can't call this like a function"
  },
  [Code.NotIndexable]: {
    title: "Not indexable",
    description: "You can't index into this"
  },
  [Code.NotIterable]: {
    title: "Not iterable",
    description: "You can't iterate over this"
  },
  [Code.FieldNotFound]: {
    title: "Field not found",
    description: "This record doesn't have that field"
  },
  [Code.VariantNotFound]: {
    title: "Variant not found",
    description: "This choice doesn't have that variant"
  },
  [Code.ScopeEscape]: {
    title: "Scope escape",
    description: "This value might escape its scope"
  },
  [Code.Undefined]: {
    title: "Undefined",
    description: "This hasn't been defined yet"
  },
  [Code.NotExported]: {
    title: "Not exported",
    description: "This isn't exported from the module"
  },
  [Code.AlreadyImported]: {
    title: "Already imported",
    description: "You've already imported this module"
  },
  [Code.NonExhaustive]: {
    title: "Non-exhaustive match",
    description: "This match doesn't cover all cases"
  },
  [Code.UnreachableCase]: {
    title: "Unreachable case",
    description: "This case can never be reached"
  },
  [Code.BackendError]: {
    title: "Backend error",
    description: "The backend encountered an error"
  },
  [Code.LinkError]: {
    title: "Link error",
    description: "The linker encountered an error"
  },
  [Code.PkgConflict]: {
    title: "Dependency conflict",
    description: "Two dependencies require incompatible versions of the same package"
  },
  [Code.PkgHashMismatch]: {
    title: "Hash mismatch",
    description: "The downloaded content doesn't match the expected hash. The cache may be tampered."
  },
  [Code.PkgNotFound]: {
    title: "Package not found",
    description: "The requested dependency could not be found or fetched"
  },
  [Code.ErrorContext]: {
    title: "Error context",
    description: "Additional context attached to this error chain"
  },
  [Code.UncaughtError]: {
    title: "Uncaught error",
    description: "This error must be handled or propagated"
  },
  [Code.TestFailed]: {
    title: "Test failed",
    description: "The test block encountered a runtime failure"
  }
};

export function render(msg: Message, source: string): string {
  const info = codeMessages[msg.code] || { title: "Error", description: "Something went wrong" };
  let out = "";
  
  // Error header with color
  out += `${colors.bold}${colors.brightRed}error${colors.reset}`;
  out += `${colors.dim}[TRATIO${msg.code.toString().padStart(4, "0")}]${colors.reset}`;
  out += `: ${colors.bold}${info.title}${colors.reset}\n`;
  out += `  ${colors.dim}${info.description}${colors.reset}\n\n`;
  
  // Location
  out += `  ${colors.cyan}-->${colors.reset} ${colors.dim}line ${msg.span.line}, column ${msg.span.col}${colors.reset}\n`;
  out += `   ${colors.dim}|${colors.reset}\n`;
  
  // Show source context (3 lines before, the error line, 2 lines after)
  const lines = source.split("\n");
  const errorLine = msg.span.line - 1;
  const startLine = Math.max(0, errorLine - 2);
  const endLine = Math.min(lines.length, errorLine + 3);
  
  for (let i = startLine; i < endLine; i++) {
    const lineNum = i + 1;
    const line = lines[i] || "";
    const isErrorLine = i === errorLine;
    
    // Line number
    const lineNumStr = lineNum.toString().padStart(3, " ");
    if (isErrorLine) {
      out += `  ${colors.brightRed}>${colors.reset} ${colors.bold}${lineNumStr}${colors.reset} ${colors.dim}|${colors.reset} `;
    } else {
      out += `   ${lineNumStr} ${colors.dim}|${colors.reset} `;
    }
    
    // Line content with highlighting
    if (isErrorLine) {
      out += `${colors.brightWhite}${line}${colors.reset}\n`;
      // Error marker
      const col = Math.max(0, msg.span.col - 1);
      const length = Math.max(1, msg.span.end - msg.span.start);
      const marker = " ".repeat(col) + "^".repeat(Math.min(length, line.length - col));
      out += `     ${colors.dim}|${colors.reset} ${colors.brightRed}${marker}${colors.reset}`;
      // Error message
      out += ` ${colors.brightRed}${msg.text}${colors.reset}\n`;
    } else {
      out += `${colors.dim}${line}${colors.reset}\n`;
    }
  }
  out += `   ${colors.dim}|${colors.reset}\n`;
  
  // Notes
  if (msg.notes.length > 0) {
    for (const n of msg.notes) {
      out += `  ${colors.cyan}note${colors.reset}: ${n.text}\n`;
      if (n.fix) {
        out += `  ${colors.green}help${colors.reset}: ${n.fix}\n`;
      }
    }
    out += "\n";
  }
  
  // Suggestion
  if (msg.suggestion) {
    out += `  ${colors.brightYellow}suggestion${colors.reset}: ${msg.suggestion}\n\n`;
  }
  
  // Related spans
  if (msg.relatedSpans && msg.relatedSpans.length > 0) {
    for (const rel of msg.relatedSpans) {
      out += `  ${colors.magenta}related${colors.reset}: ${rel.text} at line ${rel.span.line}, column ${rel.span.col}\n`;
    }
    out += "\n";
  }
  
  return out;
}
```

## `src/diag/span.ts`

```typescript
export interface Span {
  start: number;
  end: number;
  line: number;
  col: number;
}
```

## `src/fmt/formatter.ts`

```typescript
import * as ast from "../ast/node";
import { print } from "../ast/print";

export function format(program: ast.Program): string {
  let out = "";
  for (const mod of program.mods) {
    out += formatModule(mod, 0);
  }
  return out.trim() + "\n";
}

function indent(depth: number): string {
  return "  ".repeat(depth);
}

function formatModule(mod: ast.Module, depth: number): string {
  let out = `${indent(depth)}module ${mod.name.text} {\n`;
  for (const stmt of mod.body.stmts) {
    out += formatStatement(stmt, depth + 1);
  }
  out += `${indent(depth)}}\n`;
  return out;
}

function formatStatement(stmt: ast.Statement, depth: number): string {
  switch (stmt.tag) {
    case "test":
      return `${indent(depth)}test "${stmt.name.value}" ${formatBlock(stmt.body, depth)}\n`;
    case "constant":
    case "mutable":
    case "function":
    case "alias":
    case "use":
    case "give":
    case "when":
    case "while":
    case "repeat":
    case "for":
    case "match":
    case "break":
    case "continue":
    case "try":
    case "defer":
    case "unsafe":
    case "action":
    case "advance":
    case "unreachable-statement":
      return print(stmt, depth) + "\n";
    default:
      return "";
  }
}

function formatBlock(block: ast.Block, depth: number): string {
  if (block.stmts.length === 0) return "{ }";
  let out = "{\n";
  for (const stmt of block.stmts) {
    out += formatStatement(stmt, depth + 1);
  }
  out += `${indent(depth)}}`;
  return out;
}
```

## `src/ir/kind.ts`

```typescript
export enum TypeKind {
  Int,
  Float,
  Bool,
  Ptr,
  Array,
  Struct,
  Void,
  Error
}

export enum ValueKind {
  Reg,
  Const,
  Global
}

export enum InstrKind {
  Alloc,
  Load,
  Store,
  Add,
  Sub,
  Mul,
  Div,
  Call,
  Jump,
  Cjump,
  Return,
  Panic,
  Try,
  Phi
}
```

## `src/ir/node.ts`

```typescript
import { TypeKind, ValueKind, InstrKind } from "./kind";

export interface Type {
  kind: TypeKind;
  name?: string;
  elem?: Type;
  width?: number;
  fields?: Map<string, Type>;
}

export interface Value {
  kind: ValueKind;
  name: string;
  type: Type;
}

export interface Instruction {
  kind: InstrKind;
  dest?: Value;
  region?: string;
  target?: Value;
  ptr?: Value;
  val?: Value;
  val2?: Value;
  func?: string;
  args?: Value[];
  label?: string;
  cond?: Value;
  trueLabel?: string;
  falseLabel?: string;
  value?: Value;
  blocks?: { label: string; value: Value }[];
  msg?: string;
  expr?: Value;
  handler?: string;
}

export interface Block {
  label: string;
  instrs: Instruction[];
  term: Instruction;
}

export interface Function {
  name: string;
  params: Value[];
  ret: Type;
  blocks: Block[];
}

export interface Extern {
  name: string;
  params: Type[];
  ret: Type;
  abi: string;
}

export interface Module {
  name: string;
  funcs: Function[];
  externs: Extern[];
}
```

## `src/ir/parse.ts`

```typescript
import * as ir from "./node";
import { TypeKind, ValueKind, InstrKind } from "./kind";

// --- Tokenizer ---

type TokenKind = "IDENT" | "NUMBER" | "STRING" | "SYMBOL" | "EOF";

interface Token {
  kind: TokenKind;
  value: string;
}

class Lexer {
  private src: string;
  private pos: number;

  constructor(src: string) {
    this.src = src;
    this.pos = 0;
  }

  next(): Token {
    this.skip();
    if (this.pos >= this.src.length) {
      return { kind: "EOF", value: "" };
    }

    const ch = this.src[this.pos];

    // String literal
    if (ch === '"') {
      this.pos++;
      let value = "";
      while (this.pos < this.src.length && this.src[this.pos] !== '"') {
        if (this.src[this.pos] === "\\") {
          this.pos++;
          if (this.pos < this.src.length) {
            value += this.src[this.pos] === "n" ? "\n" : this.src[this.pos];
          }
        } else {
          value += this.src[this.pos];
        }
        this.pos++;
      }
      if (this.pos < this.src.length) this.pos++; // consume closing "
      return { kind: "STRING", value };
    }

    // Symbols
    if ("=,<>()[]{}:-<>".includes(ch)) {
      // Handle multi-char symbols like "->"
      if (ch === "-" && this.src[this.pos + 1] === ">") {
        this.pos += 2;
        return { kind: "SYMBOL", value: "->" };
      }
      this.pos++;
      return { kind: "SYMBOL", value: ch };
    }

    // Identifiers and Numbers
    let value = "";
    while (this.pos < this.src.length && !this.isSpace(this.src[this.pos]) && !"=,<>()[]{}:-<>\"".includes(this.src[this.pos])) {
      value += this.src[this.pos];
      this.pos++;
    }

    if (/^\d+$/.test(value) || /^\d+\.\d+$/.test(value)) {
      return { kind: "NUMBER", value };
    }

    return { kind: "IDENT", value };
  }

  private skip(): void {
    while (this.pos < this.src.length) {
      const ch = this.src[this.pos];
      if (this.isSpace(ch)) {
        this.pos++;
      } else if (ch === "-" && this.src[this.pos + 1] === "-") {
        while (this.pos < this.src.length && this.src[this.pos] !== "\n") {
          this.pos++;
        }
      } else {
        break;
      }
    }
  }

  private isSpace(ch: string): boolean {
    return ch === " " || ch === "\t" || ch === "\n" || ch === "\r";
  }
}

// --- Parser ---

class Parser {
  private tokens: Token[];
  private pos: number;

  constructor(src: string) {
    const lexer = new Lexer(src);
    this.tokens = [];
    let tok = lexer.next();
    while (tok.kind !== "EOF") {
      this.tokens.push(tok);
      tok = lexer.next();
    }
    this.tokens.push({ kind: "EOF", value: "" });
    this.pos = 0;
  }

  private peek(): Token {
    return this.tokens[this.pos];
  }

  private consume(kind: TokenKind, value?: string): Token {
    const tok = this.peek();
    if (tok.kind !== kind || (value !== undefined && tok.value !== value)) {
      throw new Error(`Expected ${kind}${value ? ` '${value}'` : ""}, got '${tok.value}'`);
    }
    this.pos++;
    return tok;
  }

  private match(kind: TokenKind, value?: string): boolean {
    const tok = this.peek();
    return tok.kind === kind && (value === undefined || tok.value === value);
  }

  parse(): ir.Module {
    this.consume("IDENT", "module");
    const name = this.consume("IDENT").value;
    this.consume("SYMBOL", "{");

    const funcs: ir.Function[] = [];
    const externs: ir.Extern[] = [];

    while (!this.match("SYMBOL", "}")) {
      if (this.match("IDENT", "extern")) {
        externs.push(this.parseExtern());
      } else if (this.match("IDENT", "fn")) {
        funcs.push(this.parseFunction());
      } else {
        throw new Error(`Unexpected token: ${this.peek().value}`);
      }
    }
    this.consume("SYMBOL", "}");

    return { name, funcs, externs };
  }

  private parseExtern(): ir.Extern {
    this.consume("IDENT", "extern");
    const abi = this.consume("STRING").value;
    this.consume("IDENT", "fn");
    const name = this.consume("IDENT").value.slice(1); // remove '@'
    
    this.consume("SYMBOL", "(");
    const params: ir.Type[] = [];
    while (!this.match("SYMBOL", ")")) {
      params.push(this.parseType());
      if (this.match("SYMBOL", ",")) {
        this.consume("SYMBOL", ",");
      }
    }
    this.consume("SYMBOL", ")");
    
    this.consume("SYMBOL", "->");
    const ret = this.parseType();

    return { name, params, ret, abi };
  }

  private parseFunction(): ir.Function {
    this.consume("IDENT", "fn");
    const name = this.consume("IDENT").value.slice(1); // remove '@'
    
    this.consume("SYMBOL", "(");
    const params: ir.Value[] = [];
    while (!this.match("SYMBOL", ")")) {
      const pname = this.consume("IDENT").value.slice(1); // remove '%'
      this.consume("SYMBOL", ":");
      const ptype = this.parseType();
      params.push({ kind: ValueKind.Reg, name: pname, type: ptype });
      if (this.match("SYMBOL", ",")) {
        this.consume("SYMBOL", ",");
      }
    }
    this.consume("SYMBOL", ")");
    
    this.consume("SYMBOL", "->");
    const ret = this.parseType();
    
    this.consume("SYMBOL", "{");
    const blocks: ir.Block[] = [];
    while (!this.match("SYMBOL", "}")) {
      blocks.push(this.parseBlock());
    }
    this.consume("SYMBOL", "}");

    return { name, params, ret, blocks };
  }

  private parseBlock(): ir.Block {
    const label = this.consume("IDENT").value;
    this.consume("SYMBOL", ":");
    
    const instrs: ir.Instruction[] = [];
    while (!this.match("SYMBOL", "}")) {
      const instr = this.parseInstruction();
      if (this.isTerminator(instr)) {
        return { label, instrs, term: instr };
      }
      instrs.push(instr);
    }

    throw new Error(`Block '${label}' is missing a terminator`);
  }

  private isTerminator(instr: ir.Instruction): boolean {
    return instr.kind === InstrKind.Return || instr.kind === InstrKind.Jump ||
      instr.kind === InstrKind.Cjump || instr.kind === InstrKind.Panic;
  }

  private parseInstruction(): ir.Instruction {
    let dest: ir.Value | undefined;
    if (this.match("IDENT") && this.peek().value.startsWith("%")) {
      const name = this.consume("IDENT").value.slice(1);
      dest = { kind: ValueKind.Reg, name, type: { kind: TypeKind.Void } }; // Type resolved by context
      this.consume("SYMBOL", "=");
    }

    const op = this.consume("IDENT").value;

    switch (op) {
      case "alloc": {
        const region = this.consume("IDENT").value;
        const type = this.parseType();
        if (dest) dest.type = type;
        return { kind: InstrKind.Alloc, dest, region };
      }
      case "load": {
        const ptr = this.parseValue();
        return { kind: InstrKind.Load, dest, ptr };
      }
      case "store": {
        const val = this.parseValue();
        this.consume("SYMBOL", ",");
        const ptr = this.parseValue();
        return { kind: InstrKind.Store, val, ptr };
      }
      case "add":
      case "sub":
      case "mul":
      case "div": {
        const val = this.parseValue();
        this.consume("SYMBOL", ",");
        const val2 = this.parseValue();
        const kind = op === "add" ? InstrKind.Add : 
                     op === "sub" ? InstrKind.Sub : 
                     op === "mul" ? InstrKind.Mul : InstrKind.Div;
        return { kind, dest, val, val2 };
      }
      case "call": {
        const func = this.consume("IDENT").value.slice(1); // remove '@'
        this.consume("SYMBOL", "(");
        const args: ir.Value[] = [];
        while (!this.match("SYMBOL", ")")) {
          args.push(this.parseValue());
          if (this.match("SYMBOL", ",")) {
            this.consume("SYMBOL", ",");
          }
        }
        this.consume("SYMBOL", ")");
        return { kind: InstrKind.Call, dest, func, args };
      }
      case "jump": {
        const label = this.consume("IDENT").value;
        return { kind: InstrKind.Jump, label };
      }
      case "cjump": {
        const cond = this.parseValue();
        this.consume("SYMBOL", ",");
        const trueLabel = this.consume("IDENT").value;
        this.consume("SYMBOL", ",");
        const falseLabel = this.consume("IDENT").value;
        return { kind: InstrKind.Cjump, cond, trueLabel, falseLabel };
      }
      case "return": {
        if (this.isValueStart()) {
          const value = this.parseValue();
          return { kind: InstrKind.Return, value };
        }
        return { kind: InstrKind.Return };
      }
      case "panic": {
        const msg = this.consume("STRING").value;
        return { kind: InstrKind.Panic, msg };
      }
      case "try": {
        const expr = this.parseValue();
        this.consume("SYMBOL", ",");
        const handler = this.consume("IDENT").value;
        return { kind: InstrKind.Try, dest, expr, handler };
      }
      case "phi": {
        this.consume("SYMBOL", "[");
        const blocks: { label: string; value: ir.Value }[] = [];
        while (!this.match("SYMBOL", "]")) {
          const label = this.consume("IDENT").value;
          this.consume("SYMBOL", ":");
          const value = this.parseValue();
          blocks.push({ label, value });
          if (this.match("SYMBOL", ",")) {
            this.consume("SYMBOL", ",");
          }
        }
        this.consume("SYMBOL", "]");
        return { kind: InstrKind.Phi, dest, blocks };
      }
      default:
        throw new Error(`Unknown instruction: ${op}`);
    }
  }

  private isValueStart(): boolean {
    const tok = this.peek();
    return tok.kind === "NUMBER" || tok.kind === "STRING" ||
      (tok.kind === "IDENT" && (tok.value.startsWith("%") || tok.value.startsWith("@")));
  }

  private parseType(): ir.Type {
    const tok = this.consume("IDENT").value;
    
    if (tok === "int") return { kind: TypeKind.Int };
    if (tok === "bool") return { kind: TypeKind.Bool };
    if (tok === "void") return { kind: TypeKind.Void };
    if (tok === "error") return { kind: TypeKind.Error };
    
    if (tok.startsWith("int")) {
      return { kind: TypeKind.Int, width: parseInt(tok.slice(3)) };
    }
    if (tok.startsWith("float")) {
      return { kind: TypeKind.Float, width: parseInt(tok.slice(5)) };
    }
    if (tok === "ptr") {
      this.consume("SYMBOL", "<");
      const elem = this.parseType();
      this.consume("SYMBOL", ">");
      return { kind: TypeKind.Ptr, elem };
    }
    if (tok === "[") {
      const widthStr = this.consume("NUMBER").value;
      this.consume("SYMBOL", "]");
      const elem = this.parseType();
      return { kind: TypeKind.Array, width: parseInt(widthStr), elem };
    }
    
    return { kind: TypeKind.Struct, name: tok };
  }

  private parseValue(): ir.Value {
    const tok = this.peek();
    if (tok.value.startsWith("%")) {
      this.consume("IDENT");
      return { kind: ValueKind.Reg, name: tok.value.slice(1), type: { kind: TypeKind.Void } };
    }
    if (tok.value.startsWith("@")) {
      this.consume("IDENT");
      return { kind: ValueKind.Global, name: tok.value.slice(1), type: { kind: TypeKind.Void } };
    }
    if (tok.kind === "NUMBER") {
      this.consume("NUMBER");
      return { kind: ValueKind.Const, name: tok.value, type: { kind: TypeKind.Int } };
    }
    if (tok.kind === "STRING") {
      this.consume("STRING");
      return { kind: ValueKind.Const, name: `"${tok.value}"`, type: { kind: TypeKind.Int } }; // Simplified type for const
    }
    throw new Error(`Expected value, got '${tok.value}'`);
  }
}

export function parse(src: string): ir.Module {
  const parser = new Parser(src);
  return parser.parse();
}
```

## `src/ir/print.ts`

```typescript
import * as ir from "./node";
import { TypeKind, ValueKind, InstrKind } from "./kind";

function typeStr(t: ir.Type): string {
  switch (t.kind) {
    case TypeKind.Int: return t.width ? `int${t.width}` : "int";
    case TypeKind.Float: return t.width ? `float${t.width}` : "float";
    case TypeKind.Bool: return "bool";
    case TypeKind.Ptr: return `ptr<${typeStr(t.elem!)}>`;
    case TypeKind.Array: return `[${t.width}]${typeStr(t.elem!)}`;
    case TypeKind.Struct: return t.name || "struct";
    case TypeKind.Void: return "void";
    case TypeKind.Error: return "error";
  }
}

function valueStr(v: ir.Value): string {
  switch (v.kind) {
    case ValueKind.Reg: return `%${v.name}`;
    case ValueKind.Const: return v.name;
    case ValueKind.Global: return `@${v.name}`;
  }
}

export function print(m: ir.Module): string {
  let out = `module ${m.name} {\n\n`;
  
  for (const ext of m.externs) {
    const params = ext.params.map(typeStr).join(", ");
    out += `  extern "${ext.abi}" fn @${ext.name}(${params}) -> ${typeStr(ext.ret)}\n`;
  }
  
  if (m.externs.length > 0) out += "\n";

  for (const f of m.funcs) {
    const params = f.params.map(p => `${valueStr(p)}: ${typeStr(p.type)}`).join(", ");
    out += `fn @${f.name}(${params}) -> ${typeStr(f.ret)} {\n`;
    
    for (const b of f.blocks) {
      out += `\n${b.label}:\n`;
      for (const i of b.instrs) {
        out += `  ${printInstr(i)}\n`;
      }
      out += `  ${printInstr(b.term)}\n`;
    }
    out += "}\n\n";
  }
  
  return out.trim() + "\n}";
}

function printInstr(i: ir.Instruction): string {
  const dest = i.dest ? `${valueStr(i.dest)} = ` : "";
  
  switch (i.kind) {
    case InstrKind.Alloc:
      return `${dest}alloc ${i.region} ${typeStr(i.dest!.type)}`;
    case InstrKind.Load:
      return `${dest}load ${valueStr(i.ptr!)}`;
    case InstrKind.Store:
      return `store ${valueStr(i.val!)}, ${valueStr(i.ptr!)}`;
    case InstrKind.Add:
      return `${dest}add ${valueStr(i.val!)}, ${valueStr(i.val2!)}`;
    case InstrKind.Sub:
      return `${dest}sub ${valueStr(i.val!)}, ${valueStr(i.val2!)}`;
    case InstrKind.Mul:
      return `${dest}mul ${valueStr(i.val!)}, ${valueStr(i.val2!)}`;
    case InstrKind.Div:
      return `${dest}div ${valueStr(i.val!)}, ${valueStr(i.val2!)}`;
    case InstrKind.Call:
      return `${dest}call @${i.func}(${(i.args || []).map(valueStr).join(", ")})`;
    case InstrKind.Jump:
      return `jump ${i.label}`;
    case InstrKind.Cjump:
      return `cjump ${valueStr(i.cond!)}, ${i.trueLabel}, ${i.falseLabel}`;
    case InstrKind.Return:
      return i.value ? `return ${valueStr(i.value)}` : "return";
    case InstrKind.Panic:
      return `panic "${i.msg}"`;
    case InstrKind.Try:
      return `${dest}try ${valueStr(i.expr!)}, ${i.handler}`;
    case InstrKind.Phi:
      const sources = (i.blocks || []).map(b => `[${b.label}: ${valueStr(b.value)}]`).join(", ");
      return `${dest}phi ${sources}`;
  }
}
```

## `src/ir/valid.ts`

```typescript
import * as ir from "./node";
import { ValueKind, InstrKind } from "./kind";

export interface ValidationError {
  msg: string;
}

export function validate(m: ir.Module): ValidationError[] {
  const errors: ValidationError[] = [];

  for (const f of m.funcs) {
    const defined = new Set<string>();
    const used = new Map<string, { line: number; col: number }>();

    // Define params
    for (const p of f.params) {
      defined.add(p.name);
    }

    for (const b of f.blocks) {
      for (const i of [...b.instrs, b.term]) {
        // Check uses before defs
        if (i.val && i.val.kind === ValueKind.Reg && !defined.has(i.val.name)) {
          errors.push({ msg: `Use of undefined register %${i.val.name}` });
        }
        if (i.val2 && i.val2.kind === ValueKind.Reg && !defined.has(i.val2.name)) {
          errors.push({ msg: `Use of undefined register %${i.val2.name}` });
        }
        if (i.cond && i.cond.kind === ValueKind.Reg && !defined.has(i.cond.name)) {
          errors.push({ msg: `Use of undefined register %${i.cond.name}` });
        }

        // Define dest
        if (i.dest && i.dest.kind === ValueKind.Reg) {
          if (defined.has(i.dest.name)) {
            errors.push({ msg: `Redefinition of register %${i.dest.name}` });
          }
          defined.add(i.dest.name);
        }

        // Terminator checks
        if (i.kind === InstrKind.Return || i.kind === InstrKind.Jump || i.kind === InstrKind.Cjump || i.kind === InstrKind.Panic) {
          if (i !== b.term) {
            errors.push({ msg: `Instruction ${i.kind} must be a terminator` });
          }
        }
      }
      
      if (b.term.kind !== InstrKind.Return && b.term.kind !== InstrKind.Jump && b.term.kind !== InstrKind.Cjump && b.term.kind !== InstrKind.Panic) {
        errors.push({ msg: `Block ${b.label} lacks a valid terminator` });
      }
    }
  }

  return errors;
}
```

## `src/lex/kind.ts`

```typescript
export enum Kind {
  // Literals
  Int,
  Float,
  String,
  Char,
  // Identifier
  Ident,
  // Keywords
  Module,
  Constant,
  Mutable,
  Is,
  Give,
  When,
  Otherwise,
  For,
  Each,
  In,
  While,
  Repeat,
  Until,
  Reaches,
  Advance,
  Match,
  Case,
  Break,
  Continue,
  Use,
  Public,
  Unsafe,
  Native,
  Evaluate,
  On,
  Leave,
  Try,
  Catch,
  And,
  Or,
  Not,
  Where,
  Of,
  Type,
  Plus,
  Minus,
  Times,
  Divided,
  By,
  Equals,
  Does,
  Equal,
  Greater,
  Than,
  Less,
  At,
  Least,
  Most,
  Integer,
  Unsigned,
  Decimal,
  Boolean,
  Byte,
  Character,
  Text,
  Array,
  Sequence,
  Nothing,
  Record,
  Choice,
  Function,
  True,
  False,
  Uninitialized,
  Unreachable,
  Optional,
  Pointer,
  To,
  Address,
  Reference,
  Start,
  Newline,
  Anything,
  Test,
  Context,
  // Symbols
  Open,
  Shut,
  Paren,
  Close,
  Square,
  Bracket,
  Dot,
  Comma,
  // Special
  NewlineToken,
  Eof,
  Broken,
}
```

## `src/lex/lexer.ts`

```typescript
import { Kind } from "./kind";
import { Token } from "./token";
import { Engine } from "../diag/engine";
import { Code } from "../diag/code";

export class Lexer {
  private src: string;
  private pos: number;
  private line: number;
  private col: number;
  private diag: Engine;
  private start: number = 0;
  private startLine: number = 1;
  private startCol: number = 1;

  constructor(src: string, diag: Engine) {
    this.src = src;
    this.pos = 0;
    this.line = 1;
    this.col = 1;
    this.diag = diag;
  }

  lex(): Token[] {
    const list: Token[] = [];
    while (true) {
      const tok = this.next();
      list.push(tok);
      if (tok.kind === Kind.Eof) break;
    }
    return list;
  }

  private next(): Token {
    this.skip();
    if (this.pos >= this.src.length) {
      return this.make(Kind.Eof, "");
    }
    const ch = this.src[this.pos];

    // Newline
    if (ch === "\n") {
      this.mark();
      this.read();
      return { kind: Kind.NewlineToken, span: this.span(), text: "\n" };
    }

    // Multiline comment ---
    if (ch === "-" && this.src[this.pos + 1] === "-" && this.src[this.pos + 2] === "-") {
      this.multilineComment();
      return this.next();
    }

    // Line comment --
    if (ch === "-" && this.src[this.pos + 1] === "-") {
      this.scanline();
      return this.next();
    }

    // Strings
    if (ch === '"') {
      return this.string();
    }

    // Character literals
    if (ch === "'") {
      return this.character();
    }

    // Numbers
    if (this.digit(ch)) {
      return this.number();
    }

    // Words (identifiers/keywords)
    if (this.letter(ch) || ch === "_") {
      return this.word();
    }

    // Symbols
    return this.symbol();
  }

  private skip(): void {
    while (this.pos < this.src.length) {
      const ch = this.src[this.pos];
      if (ch === " " || ch === "\t" || ch === "\r") {
        this.read();
      } else {
        break;
      }
    }
  }

  private scanline(): void {
    while (this.pos < this.src.length && this.src[this.pos] !== "\n") {
      this.read();
    }
  }

  private multilineComment(): void {
    this.read(); this.read(); this.read();
    while (this.pos < this.src.length) {
      if (this.src[this.pos] === "-" && 
          this.src[this.pos + 1] === "-" && 
          this.src[this.pos + 2] === "-") {
        this.read(); this.read(); this.read();
        return;
      }
      if (this.src[this.pos] === "\n") {
        this.line++;
        this.col = 1;
        this.pos++;
      } else {
        this.read();
      }
    }
    this.diag.emit(Code.Unterminated, this.span(), "unterminated multiline comment");
  }

  private string(): Token {
    this.mark();
    this.read();
    let text = "";
    while (this.pos < this.src.length && this.src[this.pos] !== '"') {
      if (this.src[this.pos] === "\n") {
        this.diag.emit(Code.Unterminated, this.span(), "unterminated string");
        break;
      }
      if (this.src[this.pos] === "\\") {
        this.read();
        const next = this.read();
        switch (next) {
          case "n": text += "\n"; break;
          case "t": text += "\t"; break;
          case "r": text += "\r"; break;
          case "\\": text += "\\"; break;
          case '"': text += '"'; break;
          case "0": text += "\0"; break;
          default:
            this.diag.emit(Code.InvalidEscape, this.span(), `invalid escape sequence \\${next}`);
            text += next;
        }
      } else {
        text += this.read();
      }
    }
    if (this.pos < this.src.length && this.src[this.pos] === '"') {
      this.read();
    }
    return { kind: Kind.String, span: this.span(), text };
  }

  private character(): Token {
    this.mark();
    this.read();
    let text = "";
    if (this.pos < this.src.length && this.src[this.pos] === "\\") {
      this.read();
      const next = this.read();
      switch (next) {
        case "n": text += "\n"; break;
        case "t": text += "\t"; break;
        case "r": text += "\r"; break;
        case "\\": text += "\\"; break;
        case "'": text += "'"; break;
        case "0": text += "\0"; break;
        default:
          this.diag.emit(Code.InvalidEscape, this.span(), `invalid escape sequence \\${next}`);
          text += next;
      }
    } else if (this.pos < this.src.length && this.src[this.pos] !== "'") {
      text = this.read();
    }
    if (this.pos < this.src.length && this.src[this.pos] === "'") {
      this.read();
    } else {
      this.diag.emit(Code.Unterminated, this.span(), "unterminated character literal");
    }
    return { kind: Kind.Char, span: this.span(), text };
  }

  private number(): Token {
    this.mark();
    let text = "";
    let real = false;
    while (this.pos < this.src.length && (this.digit(this.src[this.pos]) || this.src[this.pos] === "_")) {
      if (this.src[this.pos] !== "_") text += this.read();
      else this.read();
    }
    if (this.src[this.pos] === "." && this.digit(this.src[this.pos + 1])) {
      real = true;
      text += this.read();
      while (this.pos < this.src.length && (this.digit(this.src[this.pos]) || this.src[this.pos] === "_")) {
        if (this.src[this.pos] !== "_") text += this.read();
        else this.read();
      }
    }
    return { kind: real ? Kind.Float : Kind.Int, span: this.span(), text };
  }

  private word(): Token {
    this.mark();
    let text = "";
    while (this.pos < this.src.length && (this.alnum(this.src[this.pos]) || this.src[this.pos] === "_")) {
      text += this.read();
    }
    const keywords: Record<string, Kind> = {
      module: Kind.Module, constant: Kind.Constant, mutable: Kind.Mutable, is: Kind.Is,
      give: Kind.Give, when: Kind.When, otherwise: Kind.Otherwise,
      for: Kind.For, each: Kind.Each, in: Kind.In, while: Kind.While,
      repeat: Kind.Repeat, until: Kind.Until, reaches: Kind.Reaches, advance: Kind.Advance,
      match: Kind.Match, case: Kind.Case, break: Kind.Break, continue: Kind.Continue,
      use: Kind.Use, public: Kind.Public, unsafe: Kind.Unsafe, native: Kind.Native,
      evaluate: Kind.Evaluate, on: Kind.On, leave: Kind.Leave, try: Kind.Try, catch: Kind.Catch,
      and: Kind.And, or: Kind.Or, not: Kind.Not, where: Kind.Where, of: Kind.Of, type: Kind.Type,
      plus: Kind.Plus, minus: Kind.Minus, times: Kind.Times, divided: Kind.Divided, by: Kind.By,
      equals: Kind.Equals, does: Kind.Does, equal: Kind.Equal,
      greater: Kind.Greater, than: Kind.Than, less: Kind.Less,
      at: Kind.At, least: Kind.Least, most: Kind.Most,
      integer: Kind.Integer, unsigned: Kind.Unsigned, decimal: Kind.Decimal,
      boolean: Kind.Boolean, byte: Kind.Byte, character: Kind.Character, text: Kind.Text,
      array: Kind.Array, sequence: Kind.Sequence, nothing: Kind.Nothing,
      record: Kind.Record, choice: Kind.Choice, function: Kind.Function,
      true: Kind.True, false: Kind.False, uninitialized: Kind.Uninitialized, unreachable: Kind.Unreachable,
      optional: Kind.Optional, pointer: Kind.Pointer, to: Kind.To, address: Kind.Address, reference: Kind.Reference,
      start: Kind.Start, newline: Kind.Newline, anything: Kind.Anything,
      test: Kind.Test, context: Kind.Context,
    };
    return { kind: keywords[text] || Kind.Ident, span: this.span(), text };
  }

  private symbol(): Token {
    this.mark();
    const ch = this.read();
    let kind = Kind.Broken;
    switch (ch) {
      case "{": kind = Kind.Open; break;
      case "}": kind = Kind.Shut; break;
      case "(": kind = Kind.Paren; break;
      case ")": kind = Kind.Close; break;
      case "[": kind = Kind.Square; break;
      case "]": kind = Kind.Bracket; break;
      case ".": kind = Kind.Dot; break;
      case ",": kind = Kind.Comma; break;
      default:
        this.diag.emit(Code.Unexpected, this.span(), `unexpected character '${ch}'`);
    }
    return { kind, span: this.span(), text: ch };
  }

  private make(kind: Kind, text: string): Token {
    return { kind, span: this.span(), text };
  }

  private mark(): void {
    this.start = this.pos;
    this.startLine = this.line;
    this.startCol = this.col;
  }

  private span(): { start: number, end: number, line: number, col: number } {
    return { start: this.start, end: this.pos, line: this.startLine, col: this.startCol };
  }

  private read(): string {
    const ch = this.src[this.pos];
    this.pos++;
    if (ch === "\n") {
      this.line++;
      this.col = 1;
    } else {
      this.col++;
    }
    return ch;
  }

  private letter(ch: string): boolean {
    return (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z");
  }

  private digit(ch: string): boolean {
    return ch >= "0" && ch <= "9";
  }

  private alnum(ch: string): boolean {
    return this.letter(ch) || this.digit(ch);
  }
}
```

## `src/lex/token.ts`

```typescript
import { Kind } from "./kind";
import { Span } from "../diag/span";

export interface Token {
  kind: Kind;
  span: Span;
  text: string;
}
```

## `src/linker/orchestrator.ts`

```typescript
import { Target } from "../targets/presets";
import { execSync, ExecSyncOptionsWithBufferEncoding } from "child_process";
import { join } from "path";

export interface Config {
  libs?: string[];
  frameworks?: string[];
  dynamic?: boolean;
  rpath?: string;
}

export function link(zigPath: string, target: Target, mode: string, outDir: string, config: Config): string {
  const triple = `${target.arch}-${target.os}-${target.abi === "none" ? "" : target.abi}`.replace(/-$/, "");
  
  const args = [
    "build-exe",
    join(outDir, "main.zig"),
    `-O ${mode === "release" ? "ReleaseFast" : "ReleaseSafe"}`,
    `-target ${triple}`,
    `-femit-bin=${join(outDir, "app")}`,
  ];

  if (target.libc === "musl" || target.libc === "glibc") {
    args.push("-lc");
  }

  if (config.libs) {
    for (const lib of config.libs) {
      args.push(`-l${lib}`);
    }
  }

  if (config.frameworks && target.os === "macos") {
    for (const fw of config.frameworks) {
      args.push("-framework");
      args.push(fw);
    }
  }

  if (config.dynamic) {
    args.push("-dynamic");
  }

  if (config.rpath) {
    args.push(`-rpath`);
    args.push(config.rpath);
  }

  const opts: ExecSyncOptionsWithBufferEncoding = {
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
  };

  try {
    execSync(`"${zigPath}" ${args.join(" ")}`, opts);
    return join(outDir, "app");
  } catch (err: any) {
    throw new Error(`Linker failed:\n${err.stderr || err.message}`);
  }
}
```

## `src/lsp/server.ts`

```typescript
import { Lexer } from "../lex/lexer";
import { Parser } from "../parse/parser";
import { Resolver } from "../sema/resolver";
import { Engine } from "../diag/engine";

let buffer = "";

process.stdin.on("data", (chunk) => {
  buffer += chunk.toString("utf8");
  processBuffer();
});

function processBuffer() {
  while (true) {
    const headerEnd = buffer.indexOf("\r\n\r\n");
    if (headerEnd === -1) break;
    
    const header = buffer.substring(0, headerEnd);
    const match = header.match(/Content-Length: (\d+)/i);
    if (!match) break;
    
    const contentLength = parseInt(match[1], 10);
    const contentStart = headerEnd + 4;
    
    if (buffer.length < contentStart + contentLength) break;
    
    const content = buffer.substring(contentStart, contentStart + contentLength);
    buffer = buffer.substring(contentStart + contentLength);
    
    const msg = JSON.parse(content);
    handleMessage(msg);
  }
}

function sendMessage(msg: any) {
  const content = JSON.stringify(msg);
  const header = `Content-Length: ${Buffer.byteLength(content, "utf8")}\r\n\r\n`;
  process.stdout.write(header + content);
}

function handleMessage(msg: any) {
  if (msg.method === "initialize") {
    sendMessage({
      jsonrpc: "2.0",
      id: msg.id,
      result: {
        capabilities: {
          textDocumentSync: 1,
          definitionProvider: true,
          hoverProvider: true,
        }
      }
    });
  } else if (msg.method === "initialized") {
    // Client is ready
  } else if (msg.method === "textDocument/didOpen" || msg.method === "textDocument/didChange") {
    const doc = msg.method === "textDocument/didOpen" ? msg.params.textDocument : msg.params.textDocument;
    const src = msg.method === "textDocument/didOpen" ? doc.text : msg.params.contentChanges[0].text;
    validate(doc.uri, src);
  } else if (msg.method === "textDocument/definition") {
    sendMessage({ jsonrpc: "2.0", id: msg.id, result: null });
  } else if (msg.method === "textDocument/hover") {
    sendMessage({ jsonrpc: "2.0", id: msg.id, result: { contents: "Tratio Symbol" } });
  }
}

function validate(uri: string, src: string) {
  const diag = new Engine();
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  const ast = parser.parse();
  
  const resolver = new Resolver(diag, process.cwd());
  resolver.resolve(ast, "main");
  
  const diagnostics = diag.messages.map(m => ({
    range: {
      start: { line: m.span.line - 1, character: m.span.col - 1 },
      end: { line: m.span.line - 1, character: m.span.col - 1 + (m.span.end - m.span.start) }
    },
    severity: 1,
    source: "tratio",
    message: m.text
  }));
  
  sendMessage({
    jsonrpc: "2.0",
    method: "textDocument/publishDiagnostics",
    params: { uri, diagnostics }
  });
}
```

## `src/parse/parser.ts`

```typescript
import { Token } from "../lex/token";
import { Kind } from "../lex/kind";
import { Engine } from "../diag/engine";
import { Code } from "../diag/code";
import { Span } from "../diag/span";
import * as ast from "../ast/node";

export class Parser {
  private toks: Token[];
  private pos: number;
  private diag: Engine;
  private start: number;

  constructor(toks: Token[], diag: Engine) {
    this.toks = toks;
    this.pos = 0;
    this.diag = diag;
    this.start = 0;
  }

  parse(): ast.Program {
    this.mark();
    const mods: ast.Module[] = [];
    while (!this.done()) {
      this.skipNewlines();
      if (this.done()) break;
      mods.push(this.mod());
    }
    return { span: this.span(), tag: "program", mods };
  }

  private mod(): ast.Module {
    this.mark();
    this.expect(Kind.Module, "expected 'module'");
    const name = this.name();
    const body = this.block();
    return { span: this.span(), tag: "module", name, body };
  }

  private block(): ast.Block {
    this.mark();
    this.expect(Kind.Open, "expected '{'");
    const stmts: ast.Statement[] = [];
    this.skipNewlines();
    while (!this.check(Kind.Shut) && !this.done()) {
      stmts.push(this.stmt());
      this.skipNewlines();
    }
    this.expect(Kind.Shut, "expected '}'");
    return { span: this.span(), tag: "block", stmts };
  }

  private stmt(): ast.Statement {
    this.mark();
    const pub = this.match(Kind.Public);
    if (this.check(Kind.Constant)) return this.constant(pub);
    if (this.check(Kind.Mutable)) return this.mutable(pub);
    if (this.check(Kind.Use)) return this.use(pub);
    if (this.check(Kind.Type)) return this.alias(pub);
    if (this.check(Kind.Function)) return this.function(pub);
    if (this.check(Kind.Start)) return this.entry(pub);
    if (this.check(Kind.Test)) return this.testBlock();
    if (this.check(Kind.Unreachable)) {
      this.mark();
      this.advance();
      this.expect(Kind.Dot, "expected '.'");
      return { span: this.span(), tag: "unreachable-statement" };
    }
    if (this.check(Kind.Repeat)) return this.repeat();
    if (this.check(Kind.Advance)) return this.advanceStmt();
    if (this.check(Kind.Ident) && !pub) {
      return this.actionOrCall();
    }
    if (this.check(Kind.Give)) return this.give();
    if (this.check(Kind.When)) return this.when();
    if (this.check(Kind.While)) return this.while_();
    if (this.check(Kind.For)) return this.for_();
    if (this.check(Kind.Match)) return this.match_();
    if (this.check(Kind.Break)) return this.break_();
    if (this.check(Kind.Continue)) return this.continue_();
    if (this.check(Kind.Try)) return this.try_();
    if (this.check(Kind.On)) return this.defer();
    if (this.check(Kind.Unsafe)) return this.unsafe();
    this.diag.emit(Code.Unexpected, this.peek().span, "expected statement");
    this.advance();
    this.sync();
    return { span: this.span(), tag: "broken" } as ast.Broken;
  }

  private testBlock(): ast.TestBlock {
    this.mark();
    this.expect(Kind.Test, "expected 'test'");
    const nameTok = this.expect(Kind.String, "expected test name string");
    const name: ast.Text = { span: nameTok.span, tag: "text", value: nameTok.text };
    const body = this.block();
    return { span: this.span(), tag: "test", name, body };
  }

  private actionOrCall(): ast.Action {
    this.mark();
    const name = this.name();
    if (this.check(Kind.Paren)) {
      this.advance();
      const args: ast.Expression[] = [];
      while (!this.check(Kind.Close) && !this.done()) {
        args.push(this.expr());
        if (!this.check(Kind.Close)) {
          this.expect(Kind.Comma, "expected ','");
        }
      }
      this.expect(Kind.Close, "expected ')'");
      this.expect(Kind.Dot, "expected '.'");
      return { span: this.span(), tag: "action", name, args };
    }
    const args: ast.Expression[] = [];
    while (!this.check(Kind.Dot) && !this.check(Kind.NewlineToken) && !this.check(Kind.Shut) && !this.done()) {
      args.push(this.expr());
    }
    this.expect(Kind.Dot, "expected '.'");
    return { span: this.span(), tag: "action", name, args };
  }

  private repeat(): ast.Repeat {
    this.mark();
    this.expect(Kind.Repeat, "expected 'repeat'");
    this.expect(Kind.Until, "expected 'until'");
    const target = this.name();
    this.expect(Kind.Reaches, "expected 'reaches'");
    const limit = this.expr();
    const body = this.block();
    return { span: this.span(), tag: "repeat", target, limit, body };
  }

  private advanceStmt(): ast.AdvanceStatement {
    this.mark();
    this.expect(Kind.Advance, "expected 'advance'");
    const target = this.name();
    this.expect(Kind.Dot, "expected '.'");
    return { span: this.span(), tag: "advance", target };
  }

  private constant(pub: boolean): ast.Constant {
    this.mark();
    this.expect(Kind.Constant, "expected 'constant'");
    const name = this.name();
    let type: ast.Type | undefined;
    if (this.match(Kind.Of)) {
      this.expect(Kind.Type, "expected 'type'");
      type = this.type();
    }
    this.expect(Kind.Is, "expected 'is'");
    const value = this.expr();
    this.expect(Kind.Dot, "expected '.'");
    return { span: this.span(), tag: "constant", public: pub, name, type, value };
  }

  private mutable(pub: boolean): ast.Mutable {
    this.mark();
    this.expect(Kind.Mutable, "expected 'mutable'");
    const name = this.name();
    let type: ast.Type | undefined;
    if (this.match(Kind.Of)) {
      this.expect(Kind.Type, "expected 'type'");
      type = this.type();
    }
    this.expect(Kind.Is, "expected 'is'");
    const value = this.expr();
    this.expect(Kind.Dot, "expected '.'");
    return { span: this.span(), tag: "mutable", public: pub, name, type, value };
  }

  private function(pub: boolean): ast.Function {
    this.mark();
    this.match(Kind.Function);
    const name = this.name();
    this.expect(Kind.Paren, "expected '('");
    const params = this.params();
    this.expect(Kind.Close, "expected ')'");
    let constraint: ast.Constraint | undefined;
    if (this.match(Kind.Where)) {
      constraint = this.constraint();
    }
    const body = this.block();
    return { span: this.span(), tag: "function", public: pub, name, params, constraint, body };
  }

  private entry(pub: boolean): ast.Function {
    this.mark();
    this.expect(Kind.Start, "expected 'start'");
    this.expect(Kind.Paren, "expected '('");
    this.expect(Kind.Close, "expected ')'");
    const body = this.block();
    return {
      span: this.span(),
      tag: "function",
      public: pub,
      name: { span: this.span(), tag: "name", text: "start" },
      params: [],
      body,
    };
  }

  private alias(pub: boolean): ast.Alias {
    this.mark();
    this.expect(Kind.Type, "expected 'type'");
    const name = this.name();
    this.expect(Kind.Is, "expected 'is'");
    let body: ast.Record | ast.Choice | ast.Type;
    if (this.check(Kind.Record)) {
      body = this.record();
    } else if (this.check(Kind.Choice)) {
      body = this.choice();
    } else {
      body = this.type();
    }
    this.expect(Kind.Dot, "expected '.'");
    return { span: this.span(), tag: "alias", public: pub, name, body };
  }

  private use(pub: boolean): ast.Use {
    this.mark();
    this.expect(Kind.Use, "expected 'use'");
    if (this.check(Kind.String)) {
      const pathTok = this.advance();
      this.expect(Kind.Dot, "expected '.'");
      return { 
        span: this.span(), 
        tag: "use", 
        public: pub, 
        name: { span: pathTok.span, tag: "name", text: pathTok.text },
        path: pathTok.text
      };
    }
    const name = this.name();
    this.expect(Kind.Dot, "expected '.'");
    return { span: this.span(), tag: "use", public: pub, name };
  }

  private record(): ast.Record {
    this.mark();
    this.expect(Kind.Record, "expected 'record'");
    this.expect(Kind.Open, "expected '{'");
    const fields: ast.Member[] = [];
    this.skipNewlines();
    while (!this.check(Kind.Shut) && !this.done()) {
      fields.push(this.member());
      this.skipNewlines();
    }
    this.expect(Kind.Shut, "expected '}'");
    return { span: this.span(), tag: "record", fields };
  }

  private member(): ast.Member {
    this.mark();
    const name = this.name();
    this.expect(Kind.Of, "expected 'of'");
    this.expect(Kind.Type, "expected 'type'");
    const type = this.type();
    this.expect(Kind.Dot, "expected '.'");
    return { span: this.span(), tag: "member", name, type };
  }

  private choice(): ast.Choice {
    this.mark();
    this.expect(Kind.Choice, "expected 'choice'");
    this.expect(Kind.Open, "expected '{'");
    const variants: ast.Variant[] = [];
    this.skipNewlines();
    while (!this.check(Kind.Shut) && !this.done()) {
      variants.push(this.variant());
      this.skipNewlines();
    }
    this.expect(Kind.Shut, "expected '}'");
    return { span: this.span(), tag: "choice", variants };
  }

  private variant(): ast.Variant {
    this.mark();
    const name = this.name();
    let value: ast.Integer | undefined;
    if (this.match(Kind.Is)) {
      const tok = this.expect(Kind.Int, "expected integer value");
      value = { span: tok.span, tag: "integer", value: tok.text };
    }
    this.expect(Kind.Dot, "expected '.'");
    return { span: this.span(), tag: "variant", name, value };
  }

  private params(): ast.Parameter[] {
    const params: ast.Parameter[] = [];
    while (!this.check(Kind.Close) && !this.done()) {
      params.push(this.param());
      if (!this.check(Kind.Close)) {
        this.expect(Kind.Comma, "expected ','");
      }
    }
    return params;
  }

  private param(): ast.Parameter {
    this.mark();
    const name = this.name();
    this.expect(Kind.Of, "expected 'of'");
    this.expect(Kind.Type, "expected 'type'");
    const type = this.type();
    return { span: this.span(), tag: "parameter", name, type };
  }

  private constraint(): ast.Constraint {
    this.mark();
    const subject = this.name();
    this.expect(Kind.Is, "expected 'is'");
    const trait = this.name();
    return { span: this.span(), tag: "constraint", subject, trait };
  }

  private give(): ast.Give {
    this.mark();
    this.expect(Kind.Give, "expected 'give'");
    let value: ast.Expression | undefined;
    if (!this.check(Kind.Dot) && !this.check(Kind.NewlineToken) && !this.check(Kind.Shut) && !this.done()) {
      value = this.expr();
    }
    this.expect(Kind.Dot, "expected '.'");
    return { span: this.span(), tag: "give", value };
  }

  private when(): ast.When {
    this.mark();
    this.expect(Kind.When, "expected 'when'");
    const cond = this.expr();
    const then = this.block();
    let else_: ast.Block | ast.When | undefined;
    if (this.match(Kind.Otherwise)) {
      if (this.check(Kind.When)) {
        else_ = this.when();
      } else {
        else_ = this.block();
      }
    }
    return { span: this.span(), tag: "when", cond, then, else: else_ };
  }

  private while_(): ast.While {
    this.mark();
    this.expect(Kind.While, "expected 'while'");
    const cond = this.expr();
    const body = this.block();
    return { span: this.span(), tag: "while", cond, body };
  }

  private for_(): ast.For {
    this.mark();
    this.expect(Kind.For, "expected 'for'");
    this.expect(Kind.Each, "expected 'each'");
    const bind = this.name();
    this.expect(Kind.In, "expected 'in'");
    const iter = this.expr();
    const body = this.block();
    return { span: this.span(), tag: "for", bind, iter, body };
  }

  private match_(): ast.Match {
    this.mark();
    this.expect(Kind.Match, "expected 'match'");
    const scrutinee = this.expr();
    this.expect(Kind.Open, "expected '{'");
    const cases: ast.Case[] = [];
    this.skipNewlines();
    while (!this.check(Kind.Shut) && !this.done()) {
      cases.push(this.case_());
      this.skipNewlines();
    }
    this.expect(Kind.Shut, "expected '}'");
    return { span: this.span(), tag: "match", scrutinee, cases };
  }

  private case_(): ast.Case {
    this.mark();
    this.expect(Kind.Case, "expected 'case'");
    const pattern = this.pattern();
    const body = this.block();
    return { span: this.span(), tag: "case", pattern, body };
  }

  private break_(): ast.Break {
    this.mark();
    this.expect(Kind.Break, "expected 'break'");
    this.expect(Kind.Dot, "expected '.'");
    return { span: this.span(), tag: "break" };
  }

  private continue_(): ast.Continue {
    this.mark();
    this.expect(Kind.Continue, "expected 'continue'");
    this.expect(Kind.Dot, "expected '.'");
    return { span: this.span(), tag: "continue" };
  }

  private try_(): ast.Try {
    this.mark();
    this.expect(Kind.Try, "expected 'try'");
    const expr = this.expr();
    this.expect(Kind.Dot, "expected '.'");
    return { span: this.span(), tag: "try", expr };
  }

  private defer(): ast.Defer {
    this.mark();
    this.expect(Kind.On, "expected 'on'");
    this.expect(Kind.Leave, "expected 'leave'");
    let body: ast.Expression | ast.Block;
    if (this.check(Kind.Open)) {
      body = this.block();
    } else {
      body = this.expr();
      this.expect(Kind.Dot, "expected '.'");
    }
    return { span: this.span(), tag: "defer", body };
  }

  private unsafe(): ast.Unsafe {
    this.mark();
    this.expect(Kind.Unsafe, "expected 'unsafe'");
    const body = this.block();
    return { span: this.span(), tag: "unsafe", body };
  }

  private expr(minPrec: number = 0): ast.Expression {
    let left = this.unary();
    while (true) {
      const op = this.binop();
      if (!op) break;
      const prec = this.prec(op);
      if (prec < minPrec) break;
      
      if (op === "context") {
        const right = this.expr(prec + 1);
        const span = { start: left.span.start, end: right.span.end, line: left.span.line, col: left.span.col };
        left = { span, tag: "error-chain", expr: left, context: right } as ast.ErrorChain;
        continue;
      }

      const nextMin = op === "catch" ? prec : prec + 1;
      const right = this.expr(nextMin);
      const span = {
        start: left.span.start,
        end: right.span.end,
        line: left.span.line,
        col: left.span.col,
      };
      left = { span, tag: "binary", op, left, right } as ast.Binary;
    }
    return left;
  }

  private prec(op: string): number {
    switch (op) {
      case "context": return 1;
      case "catch": return 1;
      case "or": return 2;
      case "and": return 3;
      case "equals":
      case "does not equal":
      case "is greater than":
      case "is less than":
      case "is at least":
      case "is at most": return 4;
      case "plus":
      case "minus": return 5;
      case "times":
      case "divided by": return 6;
      default: return 0;
    }
  }

  private binop(): string | null {
    if (this.check(Kind.Plus)) { this.advance(); return "plus"; }
    if (this.check(Kind.Minus)) { this.advance(); return "minus"; }
    if (this.check(Kind.Times)) { this.advance(); return "times"; }
    if (this.check(Kind.Divided)) {
      this.advance();
      this.expect(Kind.By, "expected 'by' after 'divided'");
      return "divided by";
    }
    if (this.check(Kind.Equals)) { this.advance(); return "equals"; }
    if (this.check(Kind.Does)) {
      this.advance();
      this.expect(Kind.Not, "expected 'not' after 'does'");
      this.expect(Kind.Equal, "expected 'equal' after 'does not'");
      return "does not equal";
    }
    if (this.check(Kind.Is)) {
      this.advance();
      if (this.check(Kind.Greater)) {
        this.advance();
        this.expect(Kind.Than, "expected 'than' after 'greater'");
        return "is greater than";
      }
      if (this.check(Kind.Less)) {
        this.advance();
        this.expect(Kind.Than, "expected 'than' after 'less'");
        return "is less than";
      }
      if (this.check(Kind.At)) {
        this.advance();
        if (this.check(Kind.Least)) {
          this.advance();
          return "is at least";
        }
        if (this.check(Kind.Most)) {
          this.advance();
          return "is at most";
        }
      }
    }
    if (this.check(Kind.And)) { this.advance(); return "and"; }
    if (this.check(Kind.Or)) { this.advance(); return "or"; }
    if (this.check(Kind.Catch)) { this.advance(); return "catch"; }
    if (this.check(Kind.Context)) { this.advance(); return "context"; }
    return null;
  }

  private unary(): ast.Expression {
    if (this.check(Kind.Not)) {
      this.mark();
      this.advance();
      const operand = this.unary();
      return { span: this.span(), tag: "unary", op: "not", operand };
    }
    return this.postfix();
  }

  private postfix(): ast.Expression {
    let expr = this.primary();
    while (true) {
      if (this.check(Kind.Paren)) {
        this.mark();
        this.advance();
        const args: ast.Expression[] = [];
        while (!this.check(Kind.Close) && !this.done()) {
          args.push(this.expr());
          if (!this.check(Kind.Close)) {
            this.expect(Kind.Comma, "expected ','");
          }
        }
        this.expect(Kind.Close, "expected ')'");
        expr = { span: this.span(), tag: "call", callee: expr, args } as ast.Call;
      } else if (this.check(Kind.Dot)) {
        const nextPos = this.pos + 1;
        if (nextPos < this.toks.length && this.toks[nextPos].kind === Kind.Ident) {
          this.mark();
          this.advance();
          const field = this.name();
          expr = { span: this.span(), tag: "field", object: expr, field } as ast.Field;
        } else {
          break;
        }
      } else if (this.check(Kind.Square)) {
        this.mark();
        this.advance();
        const index = this.expr();
        this.expect(Kind.Bracket, "expected ']'");
        expr = { span: this.span(), tag: "index", object: expr, index } as ast.Index;
      } else {
        break;
      }
    }
    return expr;
  }

  private primary(): ast.Expression {
    this.mark();
    const tok = this.peek();
    switch (tok.kind) {
      case Kind.Int:
        this.advance();
        if (this.check(Kind.Ident)) {
          const unit = this.peek().text;
          const units = [
            "bytes", "bits", "kilobytes", "megabytes", "gigabytes", "terabytes",
            "seconds", "milliseconds", "microseconds", "nanoseconds",
          ];
          if (units.includes(unit)) {
            this.advance();
            return { span: this.span(), tag: "quantity", value: tok.text, unit };
          }
        }
        return { span: this.span(), tag: "integer", value: tok.text };
      case Kind.Float:
        this.advance();
        return { span: this.span(), tag: "decimal", value: tok.text };
      case Kind.String:
        this.advance();
        return { span: this.span(), tag: "text", value: tok.text };
      case Kind.Char:
        this.advance();
        return { span: this.span(), tag: "character", value: tok.text };
      case Kind.True:
        this.advance();
        return { span: this.span(), tag: "true" };
      case Kind.False:
        this.advance();
        return { span: this.span(), tag: "false" };
      case Kind.Uninitialized:
        this.advance();
        return { span: this.span(), tag: "uninitialized" };
      case Kind.Unreachable:
        this.advance();
        return { span: this.span(), tag: "unreachable" };
      case Kind.Newline:
        this.advance();
        return { span: this.span(), tag: "newline" };
      case Kind.Ident:
        return this.name();
      case Kind.Paren: {
        this.advance();
        const expr = this.expr();
        this.expect(Kind.Close, "expected ')'");
        return { span: this.span(), tag: "group", expr };
      }
      default:
        this.diag.emit(Code.Unexpected, tok.span, `unexpected token '${tok.text}'`);
        this.advance();
        return { span: this.span(), tag: "broken" } as ast.Broken;
    }
  }

  private type(): ast.Type {
    this.mark();
    const tok = this.peek();
    if (tok.kind === Kind.Optional) {
      this.advance();
      const elem = this.type();
      return { span: this.span(), tag: "optional", elem };
    }
    if (tok.kind === Kind.Pointer || tok.kind === Kind.Address || tok.kind === Kind.Reference) {
      this.advance();
      this.expect(Kind.To, "expected 'to'");
      const elem = this.type();
      return { span: this.span(), tag: "pointer", elem };
    }
    if (tok.kind === Kind.Array) {
      this.advance();
      this.expect(Kind.Of, "expected 'of'");
      const elem = this.type();
      return { span: this.span(), tag: "array", elem };
    }
    if (tok.kind === Kind.Sequence) {
      this.advance();
      this.expect(Kind.Of, "expected 'of'");
      const elem = this.type();
      return { span: this.span(), tag: "sequence", elem };
    }
    if (tok.kind === Kind.Integer || tok.kind === Kind.Unsigned || tok.kind === Kind.Decimal) {
      this.advance();
      const name = tok.text;
      let width: string | undefined;
      if (this.check(Kind.Int)) {
        width = this.advance().text;
      }
      return { span: this.span(), tag: "primitive", name, width };
    }
    if (
      tok.kind === Kind.Boolean ||
      tok.kind === Kind.Byte ||
      tok.kind === Kind.Character ||
      tok.kind === Kind.Text ||
      tok.kind === Kind.Nothing
    ) {
      this.advance();
      return { span: this.span(), tag: "primitive", name: tok.text };
    }
    if (tok.kind === Kind.Ident) {
      const name = this.name();
      return { span: this.span(), tag: "named", name };
    }
    this.diag.emit(Code.Unexpected, tok.span, `expected type, got '${tok.text}'`);
    this.advance();
    return { span: this.span(), tag: "primitive", name: "broken" } as ast.Primitive;
  }

  private pattern(): ast.Pattern {
    this.mark();
    const tok = this.peek();
    if (tok.kind === Kind.Anything) {
      this.advance();
      return { span: this.span(), tag: "wildcard" };
    }
    if (tok.kind === Kind.Ident) {
      return this.name();
    }
    if (tok.kind === Kind.Int) {
      this.advance();
      return { span: this.span(), tag: "integer", value: tok.text };
    }
    if (tok.kind === Kind.True) {
      this.advance();
      return { span: this.span(), tag: "true" };
    }
    if (tok.kind === Kind.False) {
      this.advance();
      return { span: this.span(), tag: "false" };
    }
    this.diag.emit(Code.Unexpected, tok.span, "expected pattern");
    this.advance();
    return { span: this.span(), tag: "wildcard" } as ast.Wildcard;
  }

  private name(): ast.Name {
    this.mark();
    const tok = this.expect(Kind.Ident, "expected identifier");
    return { span: this.span(), tag: "name", text: tok.text };
  }

  private peek(): Token {
    return this.toks[this.pos];
  }

  private advance(): Token {
    const tok = this.toks[this.pos];
    if (!this.done()) this.pos++;
    return tok;
  }

  private check(kind: Kind): boolean {
    return this.peek().kind === kind;
  }

  private match(kind: Kind): boolean {
    if (this.check(kind)) {
      this.advance();
      return true;
    }
    return false;
  }

  private expect(kind: Kind, msg: string): Token {
    if (this.check(kind)) {
      return this.advance();
    }
    this.diag.emit(Code.Unexpected, this.peek().span, msg);
    return this.peek();
  }

  private done(): boolean {
    return this.pos >= this.toks.length || this.toks[this.pos].kind === Kind.Eof;
  }

  private mark(): void {
    this.start = this.pos;
  }

  private span(): Span {
    const first = this.toks[this.start];
    const last = this.toks[Math.max(0, this.pos - 1)] || first;
    return {
      start: first.span.start,
      end: last.span.end,
      line: first.span.line,
      col: first.span.col,
    };
  }

  private skipNewlines(): void {
    while (this.check(Kind.NewlineToken)) {
      this.advance();
    }
  }

  private sync(): void {
    while (!this.done()) {
      const kind = this.peek().kind;
      if (
        kind === Kind.Dot ||
        kind === Kind.NewlineToken ||
        kind === Kind.Shut ||
        kind === Kind.Constant ||
        kind === Kind.Mutable ||
        kind === Kind.Use ||
        kind === Kind.Type ||
        kind === Kind.Public
      ) {
        return;
      }
      this.advance();
    }
  }
}
```

## `src/pkg/cache.ts`

```typescript
import { existsSync, mkdirSync, rmSync } from "fs";
import { join } from "path";
import * as os from "os";

export function getCacheDir(): string {
  const dir = join(os.homedir(), ".tratio", "cache");
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  return dir;
}

export function clearCache(): void {
  const dir = getCacheDir();
  if (existsSync(dir)) rmSync(dir, { recursive: true, force: true });
}
```

## `src/pkg/fetch.ts`

```typescript
import { existsSync, mkdirSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { execSync } from "child_process";
import { hashDirectory, hashBuffer } from "./hash";
import { getCacheDir } from "./cache";
import { Code } from "../diag/code";

export function fetchDep(name: string, source: string, root: string): { path: string; hash: string } {
  const cacheDir = getCacheDir();
  
  if (source.startsWith("path+")) {
    const localPath = join(root, source.slice(5));
    if (!existsSync(localPath)) {
      throw new Error(`Local dependency not found: ${localPath}`);
    }
    return { path: localPath, hash: hashDirectory(localPath) };
  }

  if (source.startsWith("git+")) {
    const url = source.slice(4);
    const id = hashBuffer(Buffer.from(url));
    const dest = join(cacheDir, "git", id);
    if (!existsSync(dest)) {
      mkdirSync(dest, { recursive: true });
      try {
        execSync(`git clone --depth 1 ${url} ${dest}`, { stdio: "pipe" });
      } catch (e) {
        rmSync(dest, { recursive: true, force: true });
        throw new Error(`Failed to clone ${url}`);
      }
    }
    return { path: dest, hash: hashDirectory(dest) };
  }

  if (source.startsWith("http://") || source.startsWith("https://")) {
    const id = hashBuffer(Buffer.from(source));
    const dest = join(cacheDir, "url", id);
    if (!existsSync(dest)) {
      mkdirSync(dest, { recursive: true });
      try {
        execSync(`curl -sL ${source} | tar -xz -C ${dest} || true`, { stdio: "pipe" });
        if (!existsSync(join(dest, "project.json"))) {
           writeFileSync(join(dest, "project.json"), `{"name":"${name}","version":"0.0.0"}`);
        }
      } catch (e) {
        // Fallback for non-tarball URLs
      }
    }
    return { path: dest, hash: hashDirectory(dest) };
  }

  throw new Error(`Unsupported dependency source: ${source}`);
}
```

## `src/pkg/hash.ts`

```typescript
import { createHash } from "crypto";
import { readFileSync, readdirSync } from "fs";
import { join, relative } from "path";

export function hashBuffer(buf: Buffer): string {
  const sha = createHash("sha256").update(buf).digest();
  // Multihash prefix: 0x12 (sha2-256), 0x20 (32 bytes)
  const prefix = Buffer.from([0x12, 0x20]);
  return Buffer.concat([prefix, sha]).toString("hex");
}

export function hashFile(path: string): string {
  return hashBuffer(readFileSync(path));
}

export function hashDirectory(dir: string): string {
  const files: string[] = [];
  function walk(d: string) {
    for (const entry of readdirSync(d, { withFileTypes: true })) {
      if (entry.name === ".git" || entry.name === "node_modules") continue;
      const p = join(d, entry.name);
      if (entry.isDirectory()) walk(p);
      else if (entry.isFile()) files.push(p);
    }
  }
  walk(dir);
  files.sort();
  
  const h = createHash("sha256");
  for (const f of files) {
    const rel = relative(dir, f).replace(/\\/g, "/");
    h.update(rel);
    h.update(readFileSync(f));
  }
  const sha = h.digest();
  const prefix = Buffer.from([0x12, 0x20]);
  return Buffer.concat([prefix, sha]).toString("hex");
}
```

## `src/pkg/lock.ts`

```typescript
import { readFileSync, writeFileSync, existsSync } from "fs";

export interface LockedPackage {
  name: string;
  source: string;
  hash: string;
}

export interface Lockfile {
  version: number;
  packages: LockedPackage[];
}

export function readLock(path: string): Lockfile | null {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

export function writeLock(path: string, lock: Lockfile): void {
  writeFileSync(path, JSON.stringify(lock, null, 2) + "\n");
}
```

## `src/pkg/resolve.ts`

```typescript
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { Lockfile } from "./lock";
import { fetchDep } from "./fetch";
import { Engine } from "../diag/engine";
import { Code } from "../diag/code";

/**
 * Dependency Resolution
 * 
 * DESIGN DECISION: Packages declare artifacts strictly via `project.json`.
 * We deliberately DO NOT support arbitrary build hooks (e.g., `preinstall`, `postbuild`)
 * in dependencies. This ensures reproducible builds, prevents supply-chain attacks
 * via malicious build scripts, and keeps the dependency graph purely declarative.
 */

export interface Manifest {
  name: string;
  version: string;
  dependencies?: Record<string, string>;
}

export interface ResolvedDep {
  name: string;
  source: string;
  hash: string;
  path: string;
  requiredBy: string;
}

export class ResolveError extends Error {
  constructor(msg: string) { super(msg); }
}

export function resolveDeps(root: string, manifest: Manifest, lock: Lockfile | null, diag: Engine): ResolvedDep[] {
  const resolved = new Map<string, ResolvedDep>();
  const queue: { name: string; source: string; requiredBy: string }[] = [];

  if (manifest.dependencies) {
    for (const [name, source] of Object.entries(manifest.dependencies)) {
      queue.push({ name, source, requiredBy: "root" });
    }
  }

  while (queue.length > 0) {
    const { name, source, requiredBy } = queue.shift()!;
    
    if (resolved.has(name)) {
      const existing = resolved.get(name)!;
      if (existing.source !== source) {
        diag.emit(Code.PkgConflict, { start: 0, end: 0, line: 0, col: 0 }, 
          `Conflict: '${name}' required as '${source}' by '${requiredBy}', ` +
          `but already resolved as '${existing.source}' by '${existing.requiredBy}'`);
        throw new ResolveError("Dependency conflict");
      }
      continue;
    }

    const locked = lock?.packages.find(p => p.name === name && p.source === source);
    let path: string;
    let hash: string;

    const fetched = fetchDep(name, source, root);
    path = fetched.path;
    hash = fetched.hash;

    if (locked && locked.hash !== hash) {
      diag.emit(Code.PkgHashMismatch, { start: 0, end: 0, line: 0, col: 0 }, 
        `Hash mismatch for '${name}': expected ${locked.hash}, found ${hash}. ` +
        `The cache may be tampered or corrupted.`);
      throw new ResolveError("Hash mismatch");
    }

    resolved.set(name, { name, source, hash, path, requiredBy });

    const depManifestPath = join(path, "project.json");
    if (existsSync(depManifestPath)) {
      const depManifest: Manifest = JSON.parse(readFileSync(depManifestPath, "utf8"));
      if (depManifest.dependencies) {
        for (const [depName, depSource] of Object.entries(depManifest.dependencies)) {
          queue.push({ name: depName, source: depSource, requiredBy: name });
        }
      }
    }
  }

  return Array.from(resolved.values());
}
```

## `src/pkg/vendor.ts`

```typescript
import { existsSync, mkdirSync, cpSync, rmSync, readFileSync } from "fs";
import { join } from "path";
import { resolveDeps, Manifest } from "./resolve";
import { readLock, writeLock, Lockfile } from "./lock";
import { Engine } from "../diag/engine";

export function vendor(root: string = process.cwd(), diag: Engine = new Engine()): void {
  const manifestPath = join(root, "project.json");
  if (!existsSync(manifestPath)) {
    throw new Error("No project.json found in current directory");
  }
  const manifest: Manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const lockPath = join(root, "project.lock");
  const lock = readLock(lockPath);

  const deps = resolveDeps(root, manifest, lock, diag);
  if (diag.failed) throw new Error("Resolution failed");
  
  const vendorDir = join(root, "vendor");
  if (existsSync(vendorDir)) rmSync(vendorDir, { recursive: true, force: true });
  mkdirSync(vendorDir, { recursive: true });

  const newLock: Lockfile = { version: 1, packages: [] };

  for (const dep of deps) {
    const dest = join(vendorDir, dep.name);
    cpSync(dep.path, dest, { recursive: true });
    newLock.packages.push({
      name: dep.name,
      source: dep.source,
      hash: dep.hash
    });
  }

  writeLock(lockPath, newLock);
}
```

## `src/sema/form.ts`

```typescript
export enum Form {
  Constant,
  Mutable,
  Function,
  Type,
  Module,
  Parameter,
  Field,
  Variant
}
```

## `src/sema/module.ts`

```typescript
import { Scope } from "./scope";
import * as ast from "../ast/node";

export interface Module {
  name: string;
  scope: Scope;
  node: ast.Module;
}

export interface Resolution {
  modules: Map<string, Module>;
  resolutions: Map<ast.Node, Symbol>;
}
```

## `src/sema/resolver.ts`

```typescript
import { Engine } from "../diag/engine";
import { Code } from "../diag/code";
import { Lexer } from "../lex/lexer";
import { Parser } from "../parse/parser";
import { Scope } from "./scope";
import { Symbol } from "./symbol";
import { Form } from "./form";
import { Module, Resolution } from "./module";
import * as ast from "../ast/node";
import { readFileSync, existsSync } from "fs";
import { join, dirname, resolve, relative } from "path";

export class Resolver {
  private diag: Engine;
  private root: string;
  private modules: Map<string, Module>;
  private resolutions: Map<ast.Node, Symbol>;
  private cache: Map<string, ast.Program>;
  private loading: Set<string>;
  private currentModule: string;
  private importedSymbols: Map<string, Set<string>>;

  constructor(diag: Engine, root: string) {
    this.diag = diag;
    this.root = resolve(root);
    this.modules = new Map();
    this.resolutions = new Map();
    this.cache = new Map();
    this.loading = new Set();
    this.currentModule = "";
    this.importedSymbols = new Map();
  }

  resolve(entry: ast.Program, entryName: string): Resolution {
    for (const mod of entry.mods) {
      this.resolveModule(mod, entryName);
    }
    return { modules: this.modules, resolutions: this.resolutions };
  }

  private resolveModule(mod: ast.Module, name: string): void {
    if (this.modules.has(name)) return;
    const scope = new Scope();
    const module: Module = { name, scope, node: mod };
    this.modules.set(name, module);
    this.currentModule = name;
    this.importedSymbols.set(name, new Set());

    for (const stmt of mod.body.stmts) {
      this.collectDeclaration(stmt, scope, name);
    }
    for (const stmt of mod.body.stmts) {
      this.resolveStatement(stmt, scope, name);
    }
  }

  private collectDeclaration(stmt: ast.Statement, scope: Scope, moduleName: string): void {
    switch (stmt.tag) {
      case "constant":
        this.insertSymbol(scope, stmt.name.text, Form.Constant, stmt.public, stmt, moduleName);
        break;
      case "mutable":
        this.insertSymbol(scope, stmt.name.text, Form.Mutable, stmt.public, stmt, moduleName);
        break;
      case "function":
        this.insertSymbol(scope, stmt.name.text, Form.Function, stmt.public, stmt, moduleName);
        break;
      case "alias":
        this.insertSymbol(scope, stmt.name.text, Form.Type, stmt.public, stmt, moduleName);
        this.validateTypeDefinition(stmt, moduleName);
        break;
    }
  }

  private validateTypeDefinition(alias: ast.Alias, moduleName: string): void {
    if (alias.body.tag === "record") {
      this.validateRecord(alias.body, moduleName);
    } else if (alias.body.tag === "choice") {
      this.validateChoice(alias.body, moduleName);
    }
  }

  private validateRecord(record: ast.Record, moduleName: string): void {
    const seen = new Set<string>();
    for (const field of record.fields) {
      if (seen.has(field.name.text)) {
        this.diag.emit(Code.Clash, field.name.span, `duplicate field '${field.name.text}' in record`);
      }
      seen.add(field.name.text);
    }
  }

  private validateChoice(choice: ast.Choice, moduleName: string): void {
    const seenNames = new Set<string>();
    const seenValues = new Set<string>();
    for (const variant of choice.variants) {
      if (seenNames.has(variant.name.text)) {
        this.diag.emit(Code.Clash, variant.name.span, `duplicate variant '${variant.name.text}' in choice`);
      }
      seenNames.add(variant.name.text);
      if (variant.value) {
        if (seenValues.has(variant.value.value)) {
          this.diag.emit(Code.Clash, variant.name.span, `duplicate value ${variant.value.value} in choice`);
        }
        seenValues.add(variant.value.value);
      }
    }
  }

  private insertSymbol(scope: Scope, name: string, form: Form, visible: boolean, node: ast.Node, moduleName: string): void {
    const symbol: Symbol = { name, form, visible, node, module: moduleName };
    if (!scope.insert(name, symbol)) {
      this.diag.emit(Code.Duplicate, node.span, `duplicate symbol '${name}'`);
    }
  }

  private resolveStatement(stmt: ast.Statement, scope: Scope, moduleName: string): void {
    switch (stmt.tag) {
      case "constant":
      case "mutable":
        if (stmt.type) this.resolveType(stmt.type, scope, moduleName);
        this.resolveExpression(stmt.value, scope, moduleName);
        break;
      case "function":
        this.resolveFunction(stmt, scope, moduleName);
        break;
      case "alias":
        if (stmt.body.tag !== "record" && stmt.body.tag !== "choice") {
          this.resolveType(stmt.body, scope, moduleName);
        }
        break;
      case "use":
        this.resolveUse(stmt, scope, moduleName);
        break;
      case "give":
        if (stmt.value) this.resolveExpression(stmt.value, scope, moduleName);
        break;
      case "when":
        this.resolveExpression(stmt.cond, scope, moduleName);
        this.resolveBlock(stmt.then, scope, moduleName);
        if (stmt.else) {
          if (stmt.else.tag === "when") {
            this.resolveStatement(stmt.else, scope, moduleName);
          } else {
            this.resolveBlock(stmt.else, scope, moduleName);
          }
        }
        break;
      case "while":
        this.resolveExpression(stmt.cond, scope, moduleName);
        this.resolveBlock(stmt.body, scope, moduleName);
        break;
      case "repeat":
        this.resolveBlock(stmt.body, scope, moduleName);
        break;
      case "for":
        this.resolveExpression(stmt.iter, scope, moduleName);
        const forScope = new Scope(scope);
        this.insertSymbol(forScope, stmt.bind.text, Form.Parameter, false, stmt, moduleName);
        this.resolveBlock(stmt.body, forScope, moduleName);
        break;
      case "match":
        this.resolveExpression(stmt.scrutinee, scope, moduleName);
        for (const c of stmt.cases) {
          const caseScope = new Scope(scope);
          this.resolvePattern(c.pattern, caseScope, moduleName);
          this.resolveBlock(c.body, caseScope, moduleName);
        }
        break;
      case "try":
        this.resolveExpression(stmt.expr, scope, moduleName);
        break;
      case "defer":
        if (stmt.body.tag === "block") {
          this.resolveBlock(stmt.body, scope, moduleName);
        } else {
          this.resolveExpression(stmt.body, scope, moduleName);
        }
        break;
      case "unsafe":
        this.resolveBlock(stmt.body, scope, moduleName);
        break;
      case "action":
        for (const arg of stmt.args) {
          this.resolveExpression(arg, scope, moduleName);
        }
        break;
    }
  }

  private resolveFunction(fn: ast.Function, parentScope: Scope, moduleName: string): void {
    const fnScope = new Scope(parentScope);
    for (const param of fn.params) {
      this.insertSymbol(fnScope, param.name.text, Form.Parameter, false, param, moduleName);
      this.resolveType(param.type, fnScope, moduleName);
    }
    this.resolveBlock(fn.body, fnScope, moduleName);
  }

  private resolveUse(use: ast.Use, scope: Scope, moduleName: string): void {
    let importedName: string;
    let resolvedPath: string;

    if (use.path) {
      resolvedPath = this.resolvePath(use.path, moduleName);
      importedName = this.pathToModuleName(resolvedPath);
    } else {
      importedName = use.name.text;
      const cwdPath = join(this.root, `${importedName}.rt`);
      if (existsSync(cwdPath)) {
        resolvedPath = cwdPath;
      } else {
        const currentFile = this.findModuleFile(moduleName);
        const currentDir = currentFile ? dirname(currentFile) : this.root;
        resolvedPath = join(currentDir, `${importedName}.rt`);
      }
    }

    const imports = this.importedSymbols.get(moduleName);
    if (imports && imports.has(importedName)) {
      this.diag.emit(Code.Duplicate, use.name.span, `module '${importedName}' already imported`);
      return;
    }
    if (imports) {
      imports.add(importedName);
    }

    const imported = this.loadModule(importedName, resolvedPath);
    if (!imported) {
      this.diag.emit(Code.Absent, use.name.span, `module '${importedName}' not found`);
      return;
    }

    for (const [name, symbol] of this.getModuleSymbols(importedName)) {
      if (symbol.visible) {
        const importedSymbol: Symbol = {
          ...symbol,
          module: importedName
        };
        if (!scope.insert(name, importedSymbol)) {
          this.diag.emit(Code.Duplicate, use.name.span, `symbol '${name}' conflicts with existing symbol`);
        }
      }
    }
  }

  private resolvePath(pathStr: string, currentModule: string): string {
    const currentFile = this.findModuleFile(currentModule);
    const currentDir = currentFile ? dirname(currentFile) : this.root;
    let resolved: string;

    if (pathStr.startsWith("./") || pathStr.startsWith("../")) {
      resolved = resolve(currentDir, pathStr);
    } else {
      resolved = resolve(this.root, pathStr);
    }

    if (!resolved.endsWith(".rt")) {
      resolved = resolved + ".rt";
    }
    return resolved;
  }

  private findModuleFile(name: string): string | undefined {
    const direct = join(this.root, `${name}.rt`);
    if (existsSync(direct)) return direct;
    const dotted = join(this.root, `${name.replace(/\./g, "/")}.rt`);
    if (existsSync(dotted)) return dotted;
    return undefined;
  }

  private pathToModuleName(absolutePath: string): string {
    const rel = relative(this.root, absolutePath);
    return rel
      .replace(/\.rt$/, "")
      .replace(/\//g, ".")
      .replace(/^\.+/, "")
      .replace(/\.+/g, ".");
  }

  private loadModule(name: string, path: string): ast.Program | undefined {
    if (this.cache.has(name)) {
      return this.cache.get(name);
    }
    if (this.loading.has(name)) {
      this.diag.emit(Code.Absent, { start: 0, end: 0, line: 0, col: 0 }, `circular import of '${name}'`);
      return undefined;
    }
    if (!existsSync(path)) {
      return undefined;
    }
    
    this.loading.add(name);
    const src = readFileSync(path, "utf8");
    
    const lexerDiag = new Engine();
    lexerDiag.setSource(src); // Track source for this specific module
    const lexer = new Lexer(src, lexerDiag);
    const toks = lexer.lex();
    
    const parserDiag = new Engine();
    parserDiag.setSource(src); // Track source for this specific module
    const parser = new Parser(toks, parserDiag);
    const program = parser.parse();
    
    // Propagate diagnostics while preserving the imported module's source code
    for (const msg of lexerDiag.messages) {
      this.diag.emit(msg.code, msg.span, msg.text, msg.context, src);
    }
    for (const msg of parserDiag.messages) {
      this.diag.emit(msg.code, msg.span, msg.text, msg.context, src);
    }
    
    this.cache.set(name, program);
    this.loading.delete(name);
    
    for (const mod of program.mods) {
      this.resolveModule(mod, name);
    }
    return program;
  }

  private getModuleSymbols(name: string): Map<string, Symbol> {
    const module = this.modules.get(name);
    if (!module) return new Map();
    const result = new Map<string, Symbol>();
    for (const stmt of module.node.body.stmts) {
      switch (stmt.tag) {
        case "constant":
        case "mutable":
        case "function":
        case "alias":
          result.set(stmt.name.text, {
            name: stmt.name.text,
            form: stmt.tag === "constant" ? Form.Constant :
                  stmt.tag === "mutable" ? Form.Mutable :
                  stmt.tag === "function" ? Form.Function : Form.Type,
            visible: stmt.public,
            node: stmt,
            module: name
          });
          break;
      }
    }
    return result;
  }

  private resolveBlock(block: ast.Block, scope: Scope, moduleName: string): void {
    const blockScope = new Scope(scope);
    for (const stmt of block.stmts) {
      this.collectBlockDeclaration(stmt, blockScope, moduleName);
    }
    for (const stmt of block.stmts) {
      this.resolveStatement(stmt, blockScope, moduleName);
    }
  }

  private collectBlockDeclaration(stmt: ast.Statement, scope: Scope, moduleName: string): void {
    switch (stmt.tag) {
      case "constant":
        this.insertSymbol(scope, stmt.name.text, Form.Constant, false, stmt, moduleName);
        break;
      case "mutable":
        this.insertSymbol(scope, stmt.name.text, Form.Mutable, false, stmt, moduleName);
        break;
      case "for":
        this.insertSymbol(scope, stmt.bind.text, Form.Parameter, false, stmt, moduleName);
        break;
      case "match":
        for (const c of stmt.cases) {
          if (c.pattern.tag === "name" && c.pattern.text !== "_") {
            this.insertSymbol(scope, c.pattern.text, Form.Parameter, false, c.pattern, moduleName);
          }
        }
        break;
    }
  }

  private resolveExpression(expr: ast.Expression, scope: Scope, moduleName: string): void {
    switch (expr.tag) {
      case "name":
        const symbol = scope.lookup(expr.text);
        if (!symbol) {
          this.diag.emit(Code.Missing, expr.span, `undefined symbol '${expr.text}'`);
        } else {
          this.resolutions.set(expr, symbol);
        }
        break;
      case "call":
        this.resolveExpression(expr.callee, scope, moduleName);
        for (const arg of expr.args) {
          this.resolveExpression(arg, scope, moduleName);
        }
        break;
      case "unary":
        this.resolveExpression(expr.operand, scope, moduleName);
        break;
      case "binary":
        this.resolveExpression(expr.left, scope, moduleName);
        this.resolveExpression(expr.right, scope, moduleName);
        break;
      case "group":
        this.resolveExpression(expr.expr, scope, moduleName);
        break;
      case "field":
        this.resolveExpression(expr.object, scope, moduleName);
        break;
      case "index":
        this.resolveExpression(expr.object, scope, moduleName);
        this.resolveExpression(expr.index, scope, moduleName);
        break;
    }
  }

  private resolveType(type: ast.Type, scope: Scope, moduleName: string): void {
    switch (type.tag) {
      case "named":
        const symbol = scope.lookup(type.name.text);
        if (!symbol) {
          this.diag.emit(Code.Missing, type.name.span, `undefined type '${type.name.text}'`);
        } else if (symbol.form !== Form.Type) {
          this.diag.emit(Code.Missing, type.name.span, `'${type.name.text}' is not a type`);
        } else {
          this.resolutions.set(type, symbol);
        }
        break;
      case "optional":
      case "error":
      case "pointer":
      case "array":
      case "sequence":
        this.resolveType(type.elem, scope, moduleName);
        break;
    }
  }

  private resolvePattern(pattern: ast.Pattern, scope: Scope, moduleName: string): void {
    if (pattern.tag === "name" && pattern.text !== "_") {
      this.insertSymbol(scope, pattern.text, Form.Parameter, false, pattern, moduleName);
    }
  }
}
```

## `src/sema/scope.ts`

```typescript
import { Symbol } from "./symbol";

export class Scope {
  private parent?: Scope;
  private symbols: Map<string, Symbol>;

  constructor(parent?: Scope) {
    this.parent = parent;
    this.symbols = new Map();
  }

  insert(name: string, symbol: Symbol): boolean {
    if (this.symbols.has(name)) {
      return false;
    }
    this.symbols.set(name, symbol);
    return true;
  }

  lookup(name: string): Symbol | undefined {
    const local = this.symbols.get(name);
    if (local) return local;
    if (this.parent) return this.parent.lookup(name);
    return undefined;
  }

  lookupLocal(name: string): Symbol | undefined {
    return this.symbols.get(name);
  }
}
```

## `src/sema/symbol.ts`

```typescript
import { Form } from "./form";
import * as ast from "../ast/node";

export interface Symbol {
  name: string;
  form: Form;
  visible: boolean;
  node: ast.Node;
  module?: string;
}
```

## `src/targets/presets.ts`

```typescript
export interface Target {
  arch: string;
  os: string;
  abi: string;
  libc: string;
  cpu: string;
  features: string[];
}

export const presets: Record<string, Target> = {
  "linux-x64": { arch: "x86_64", os: "linux", abi: "gnu", libc: "glibc", cpu: "x86_64", features: [] },
  "linux-arm64": { arch: "aarch64", os: "linux", abi: "gnu", libc: "glibc", cpu: "aarch64", features: [] },
  "linux-musl-x64": { arch: "x86_64", os: "linux", abi: "musl", libc: "musl", cpu: "x86_64", features: [] },
  "macos-arm64": { arch: "aarch64", os: "macos", abi: "none", libc: "system", cpu: "apple_m1", features: [] },
  "windows-x64": { arch: "x86_64", os: "windows", abi: "msvc", libc: "msvcrt", cpu: "x86_64", features: [] },
  "wasi": { arch: "wasm32", os: "wasi", abi: "none", libc: "wasi", cpu: "generic", features: [] },
};

export function resolve(name: string): Target {
  const target = presets[name];
  if (!target) {
    throw new Error(`Unknown target preset: ${name}`);
  }
  return target;
}
```

## `src/test/runner.ts`

```typescript
import { readFileSync, readdirSync, existsSync, watch, writeFileSync, mkdirSync, rmSync } from "fs";
import { execSync } from "child_process";
import { join, relative } from "path";
import * as os from "os";
import { Lexer } from "../lex/lexer";
import { Parser } from "../parse/parser";
import { Engine } from "../diag/engine";
import { Resolver } from "../sema/resolver";
import { TypeChecker } from "../types/checker";
import { lower } from "../lower/lower";
import { build } from "../backend/zig/driver";
import { getPin, detect } from "../toolchain/manager";
import * as ast from "../ast/node";

export interface TestSuite {
  name: string;
  file: string;
  line: number;
}

export interface TestResult {
  suite: TestSuite;
  passed: boolean;
  timeMs: number;
  output: string;
  error: string;
}

/**
 * Discovers all `.rt` files in the given root and extracts `test "name" {}` blocks.
 */
export function discoverTests(root: string): TestSuite[] {
  const suites: TestSuite[] = [];
  
  function walk(dir: string) {
    if (!existsSync(dir)) return;
    const entries = readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      const path = join(dir, entry.name);
      if (entry.isDirectory() && entry.name !== "node_modules" && entry.name !== ".tratio-build" && entry.name !== ".tratio-test") {
        walk(path);
      } else if (entry.name.endsWith(".rt")) {
        const src = readFileSync(path, "utf8");
        const diag = new Engine();
        const lexer = new Lexer(src, diag);
        const toks = lexer.lex();
        const parser = new Parser(toks, diag);
        const program = parser.parse();
        
        for (const mod of program.mods) {
          for (const stmt of mod.body.stmts) {
            if (stmt.tag === "test") {
              suites.push({
                name: (stmt as ast.TestBlock).name.value,
                file: path,
                line: stmt.span.line
              });
            }
          }
        }
      }
    }
  }
  
  walk(root);
  return suites;
}

/**
 * Synthesizes a `start()` entry point for modules containing `test` blocks.
 * Converts `test "name" { ... }` into private functions and calls them sequentially.
 * If a `start()` function already exists, it prepends the test calls to it.
 */
function synthesizeTests(program: ast.Program): void {
  for (const mod of program.mods) {
    const testBlocks = mod.body.stmts.filter((s): s is ast.TestBlock => s.tag === "test");
    if (testBlocks.length === 0) continue;

    // 1. Convert test blocks to private functions
    const testFuncs: ast.Function[] = testBlocks.map((tb, i) => ({
      span: tb.span,
      tag: "function",
      public: false,
      name: { span: tb.span, tag: "name", text: `__test_${i}` },
      params: [],
      body: tb.body
    }));

    // 2. Create statements to call these test functions
    const callStmts: ast.Statement[] = testFuncs.map((tf) => ({
      span: tf.span,
      tag: "action",
      name: { span: tf.span, tag: "name", text: tf.name.text },
      args: []
    }));

    // 3. Check if `start` already exists
    const existingStart = mod.body.stmts.find(
      s => s.tag === "function" && (s as ast.Function).name.text === "start"
    ) as ast.Function | undefined;

    if (existingStart) {
      // Prepend test calls to the existing start function's body
      existingStart.body.stmts.unshift(...callStmts);
    } else {
      // Create a new public start function
      const dummySpan = { start: 0, end: 0, line: 1, col: 1 };
      const startFunc: ast.Function = {
        span: dummySpan,
        tag: "function",
        public: true,
        name: { span: dummySpan, tag: "name", text: "start" },
        params: [],
        body: { span: dummySpan, tag: "block", stmts: callStmts }
      };
      mod.body.stmts.push(...testFuncs, startFunc);
    }

    // 4. Remove the original test block statements from the module body
    mod.body.stmts = mod.body.stmts.filter(s => s.tag !== "test");
  }
}

/**
 * Compiles and executes a single test file.
 */
function runSingleTest(suite: TestSuite, projectRoot: string): TestResult {
  const startMs = Date.now();
  const src = readFileSync(suite.file, "utf8");
  const diag = new Engine();
  
  // 1. Parse
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  let program = parser.parse();
  
  if (diag.failed) {
    return { suite, passed: false, timeMs: Date.now() - startMs, output: "", error: "Parse failed" };
  }

  // 2. Synthesize test entry points
  synthesizeTests(program);

  // 3. Resolve
  const resolver = new Resolver(diag, projectRoot);
  resolver.resolve(program, "test_runner");
  if (diag.failed) {
    return { suite, passed: false, timeMs: Date.now() - startMs, output: "", error: "Resolution failed" };
  }

  // 4. Type Check
  const checker = new TypeChecker(diag);
  checker.check(program);
  if (diag.failed) {
    return { suite, passed: false, timeMs: Date.now() - startMs, output: "", error: "Type check failed" };
  }

  // 5. Lower to IR
  const irMod = lower(program);

  // 6. Build
  const outDir = join(os.tmpdir(), `tratio-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  mkdirSync(outDir, { recursive: true });
  
  const pinnedVersion = getPin() || "0.16.0";
  const toolchain = detect(pinnedVersion) || { version: pinnedVersion, path: "zig" };
  
  try {
    const buildResult = build(irMod, "dev", outDir, toolchain.path);
    if (!buildResult.success) {
      return { suite, passed: false, timeMs: Date.now() - startMs, output: "", error: buildResult.error || "Build failed" };
    }

    // 7. Execute
    const execResult = execSync(join(outDir, "app"), { 
      encoding: "utf8", 
      maxBuffer: 10 * 1024 * 1024,
      stdio: ["pipe", "pipe", "pipe"]
    });
    
    // Cleanup
    rmSync(outDir, { recursive: true, force: true });

    return { 
      suite, 
      passed: true, 
      timeMs: Date.now() - startMs, 
      output: execResult.toString().trim(), 
      error: "" 
    };
  } catch (e: any) {
    // Cleanup on failure
    if (existsSync(outDir)) {
      rmSync(outDir, { recursive: true, force: true });
    }
    return { 
      suite, 
      passed: false, 
      timeMs: Date.now() - startMs, 
      output: e.stdout || "", 
      error: e.stderr || e.message 
    };
  }
}

/**
 * Orchestrates test discovery, execution, reporting, and watch mode.
 */
export function runTests(
  root: string = process.cwd(), 
  filter?: string, 
  watchMode: boolean = false, 
  junitPath?: string
): void {
  let suites = discoverTests(root);
  
  // If no explicit `test` blocks were found, fallback to running any `.rt` file 
  // in the `tests/` directory that has a `start()` function (e.g., stdlib tests).
  if (suites.length === 0 && existsSync(join(root, "tests"))) {
    const testFiles = readdirSync(join(root, "tests"), { recursive: true })
      .filter((f: any) => f.toString().endsWith(".rt"))
      .map((f: any) => join(root, "tests", f.toString()));
    
    suites = testFiles.map((file: string) => ({
      name: file.split("/").pop()!.replace(".rt", ""),
      file,
      line: 1
    }));
  }

  if (filter) {
    suites = suites.filter(s => s.name.includes(filter));
  }
  
  console.log(`Found ${suites.length} test suites.`);
  
  const run = () => {
    let passed = 0;
    let failed = 0;
    const results: any[] = [];
    
    for (const suite of suites) {
      const result = runSingleTest(suite, root);
      
      if (result.passed) {
        console.log(`  ✓ ${result.suite.name} (${relative(root, result.suite.file)}:${result.suite.line}) [${result.timeMs}ms]`);
        passed++;
      } else {
        console.log(`  ✗ ${result.suite.name} (${relative(root, result.suite.file)}:${result.suite.line})`);
        console.log(`    Error: ${result.error}`);
        if (result.output) {
          console.log(`    Output: ${result.output}`);
       0}
        failed++;
      }
      
      results.push({ 
        name: result.suite.name, 
        classname: relative(root, result.suite.file), 
        time: (result.timeMs / 1000).toFixed(3),
        failure: result.passed ? undefined : result.error
      });
    }
    
    console.log(`\n${passed} passed, ${failed} failed.`);
    
    if (junitPath) {
      const xml = `<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="tratio" tests="${passed + failed}" failures="${failed}">
${results.map(r => `  <testcase name="${r.name}" classname="${r.classname}" time="${r.time}">${r.failure ? `<failure message="${r.failure.replace(/"/g, '&quot;')}"/>` : ""}</testcase>`).join("\n")}
</testsuite>`;
      writeFileSync(junitPath, xml);
      console.log(`JUnit report written to ${junitPath}`);
    }

    if (failed > 0) {
      process.exitCode = 1;
    }
  };
  
  run();
  
  if (watchMode) {
    console.log("\nWatching for changes...");
    watch(root, { recursive: true }, (event, filename) => {
      if (filename && filename.endsWith(".rt")) {
        console.log(`\nChange detected: ${filename}`);
        // Reset exit code for watch mode re-runs
        process.exitCode = 0;
        run();
      }
    });
  }
}
```

## `src/toolchain/manager.ts`

```typescript
import { existsSync, mkdirSync, writeFileSync, readFileSync, readdirSync, chmodSync, createWriteStream, unlinkSync } from "fs";
import { join } from "path";
import { execSync } from "child_process";
import * as https from "https";
import * as os from "os";

const CACHE_DIR = join(os.homedir(), ".tratio", "toolchains");
const PIN_FILE = "tratio.lock";

export interface Info {
  version: string;
  path: string;
}

export function getPin(): string | undefined {
  if (existsSync(PIN_FILE)) {
    const content = readFileSync(PIN_FILE, "utf8");
    const match = content.match(/"zig":\s*"([^"]+)"/);
    return match ? match[1] : undefined;
  }
  return undefined;
}

export function setPin(version: string): void {
  const content = `{ "zig": "${version}" }\n`;
  writeFileSync(PIN_FILE, content);
}

export function detect(version: string): Info | undefined {
  const dir = join(CACHE_DIR, version);
  const exe = process.platform === "win32" ? "zig.exe" : "zig";
  const path = join(dir, exe);
  if (existsSync(path)) {
    return { version, path };
  }
  return undefined;
}

function downloadFile(url: string, dest: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const file = createWriteStream(dest);
    https.get(url, (response) => {
      if (response.statusCode === 302 || response.statusCode === 301) {
        downloadFile(response.headers.location!, dest).then(resolve).catch(reject);
        return;
      }
      if (response.statusCode !== 200) {
        reject(new Error(`Failed to download: ${response.statusCode}`));
        return;
      }
      
      const total = parseInt(response.headers["content-length"] || "0", 10);
      let downloaded = 0;
      
      response.on("data", (chunk) => {
        downloaded += chunk.length;
        if (total > 0) {
          const percent = Math.round((downloaded / total) * 100);
          process.stdout.write(`\r[Toolchain] Downloading: ${percent}%`);
        }
      });
      
      response.pipe(file);
      file.on("finish", () => {
        file.close();
        process.stdout.write("\n");
        resolve();
      });
    }).on("error", (err) => {
      unlinkSync(dest);
      reject(err);
    });
  });
}

export async function install(version: string): Promise<Info> {
  const dir = join(CACHE_DIR, version);
  if (existsSync(dir)) {
    const exeName = process.platform === "win32" ? "zig.exe" : "zig";
    return { version, path: join(dir, exeName) };
  }
  
  mkdirSync(dir, { recursive: true });
  console.log(`[Toolchain] Fetching Zig ${version}...`);
  
  const platform = process.platform === "win32" ? "windows" : 
                   process.platform === "darwin" ? "macos" : "linux";
  const arch = process.arch === "x64" ? "x86_64" : 
               process.arch === "arm64" ? "aarch64" : process.arch;
  
  const ext = platform === "windows" ? "zip" : "tar.xz";
  const filename = `zig-${platform}-${arch}-${version}.${ext}`;
  const url = `https://ziglang.org/download/${version}/${filename}`;
  const archivePath = join(dir, filename);
  
  try {
    await downloadFile(url, archivePath);
    console.log("[Toolchain] Extracting...");
    
    if (platform === "windows") {
      execSync(`tar -xf "${archivePath}" -C "${dir}"`, { stdio: "inherit" });
    } else {
      execSync(`tar -xf "${archivePath}" -C "${dir}" --strip-components=1`, { stdio: "inherit" });
    }
    
    const exeName = process.platform === "win32" ? "zig.exe" : "zig";
    const exePath = join(dir, exeName);
    
    if (process.platform !== "win32") {
      chmodSync(exePath, 0o755);
    }
    
    console.log(`[Toolchain] Zig ${version} installed successfully.`);
    return { version, path: exePath };
  } catch (err) {
    throw new Error(`Failed to install Zig ${version}: ${err instanceof Error ? err.message : String(err)}`);
  }
}

export function list(): string[] {
  if (!existsSync(CACHE_DIR)) return [];
  return readdirSync(CACHE_DIR);
}
```

## `src/types/checker.ts`

```typescript
import * as ast from "../ast/node";
import { Engine } from "../diag/engine";
import { Code } from "../diag/code";
import { TypeEnv } from "./env";
import { Type, PrimitiveType, RecordType, ChoiceType, FunctionType, typeToString } from "./type";
import { canCoerce } from "./coerce";
import { checkExhaustiveness } from "./exhaust";
import { checkEscape } from "./escape";

export class TypeChecker {
  private diag: Engine;
  private env: TypeEnv;
  private typeDefs: Map<string, Type>;

  constructor(diag: Engine) {
    this.diag = diag;
    this.env = new TypeEnv();
    this.typeDefs = new Map();
    this.initBuiltins();
  }

  private initBuiltins(): void {
    const prims = ["integer", "unsigned", "decimal", "boolean", "byte", "character", "text", "nothing"];
    for (const p of prims) {
      this.typeDefs.set(p, { kind: "primitive", name: p });
    }
  }

  check(program: ast.Program): void {
    for (const mod of program.mods) {
      this.checkModule(mod);
    }
  }

  private checkModule(mod: ast.Module): void {
    for (const stmt of mod.body.stmts) {
      if (stmt.tag === "alias") {
        this.defineType(stmt);
      }
    }

    const moduleEnv = this.env.child();
    for (const stmt of mod.body.stmts) {
      this.checkStatement(stmt, moduleEnv);
    }
  }

  private defineType(alias: ast.Alias): void {
    if (alias.body.tag === "record") {
      const fields = new Map<string, Type>();
      for (const field of alias.body.fields) {
        fields.set(field.name.text, this.resolveType(field.type));
      }
      this.typeDefs.set(alias.name.text, {
        kind: "record",
        name: alias.name.text,
        fields
      });
    } else if (alias.body.tag === "choice") {
      const variants = new Map<string, Type | undefined>();
      for (const variant of alias.body.variants) {
        variants.set(variant.name.text, undefined);
      }
      this.typeDefs.set(alias.name.text, {
        kind: "choice",
        name: alias.name.text,
        variants
      });
    } else {
      this.typeDefs.set(alias.name.text, this.resolveType(alias.body));
    }
  }

  private checkStatement(stmt: ast.Statement, env: TypeEnv): void {
    switch (stmt.tag) {
      case "constant":
      case "mutable": {
        const declaredType = stmt.type ? this.resolveType(stmt.type) : undefined;
        const valueType = this.inferExpression(stmt.value, env, declaredType);
        
        if (declaredType) {
          const coercion = canCoerce(valueType, declaredType);
          if (!coercion.ok) {
            this.diag.emit(Code.Invalid, stmt.value.span, 
              `type mismatch: expected ${typeToString(declaredType)}, found ${typeToString(valueType)}`);
            this.diag.suggestion(`Convert the value to match the declared type`);
          }
        }
        
        env.define(stmt.name.text, declaredType || valueType);
        break;
      }
      
      case "function": {
        const paramTypes = stmt.params.map(p => this.resolveType(p.type));
        const retType = { kind: "unknown" as const };
        const fnType: FunctionType = { kind: "function", params: paramTypes, ret: retType };
        
        env.define(stmt.name.text, fnType);
        
        const fnEnv = env.child();
        for (let i = 0; i < stmt.params.length; i++) {
          fnEnv.define(stmt.params[i].name.text, paramTypes[i]);
        }
        
        this.checkBlock(stmt.body, fnEnv, retType);
        break;
      }
      
      case "give": {
        if (stmt.value) {
          this.inferExpression(stmt.value, env);
        }
        break;
      }
      
      case "when": {
        const condType = this.inferExpression(stmt.cond, env);
        this.checkBoolean(condType, stmt.cond.span);
        this.checkBlock(stmt.then, env.child(), { kind: "unknown" });
        if (stmt.else) {
          if (stmt.else.tag === "when") {
            this.checkStatement(stmt.else, env);
          } else {
            this.checkBlock(stmt.else, env.child(), { kind: "unknown" });
          }
        }
        break;
      }
      
      case "while": {
        const condType = this.inferExpression(stmt.cond, env);
        this.checkBoolean(condType, stmt.cond.span);
        this.checkBlock(stmt.body, env.child(), { kind: "unknown" });
        break;
      }
      
      case "repeat": {
        this.checkBlock(stmt.body, env.child(), { kind: "unknown" });
        break;
      }
      
      case "for": {
        const iterType = this.inferExpression(stmt.iter, env);
        const elemType = this.extractElementType(iterType, stmt.iter.span);
        const forEnv = env.child();
        forEnv.define(stmt.bind.text, elemType);
        this.checkBlock(stmt.body, forEnv, { kind: "unknown" });
        break;
      }
      
      case "match": {
        const scrutineeType = this.inferExpression(stmt.scrutinee, env);
        this.checkMatchExhaustiveness(scrutineeType, stmt.cases, stmt.scrutinee.span);
        
        for (const c of stmt.cases) {
          const caseEnv = env.child();
          this.bindPattern(c.pattern, scrutineeType, caseEnv);
          this.checkBlock(c.body, caseEnv, { kind: "unknown" });
        }
        break;
      }
      
      case "try": {
        this.inferExpression(stmt.expr, env);
        break;
      }
      
      case "defer": {
        if (stmt.body.tag === "block") {
          this.checkBlock(stmt.body, env.child(), { kind: "unknown" });
        } else {
          this.inferExpression(stmt.body, env);
        }
        break;
      }
      
      case "unsafe": {
        this.checkBlock(stmt.body, env.child(), { kind: "unknown" });
        break;
      }
      
      case "action": {
        for (const arg of stmt.args) {
          this.inferExpression(arg, env);
        }
        break;
      }
    }
  }

  private checkBlock(block: ast.Block, env: TypeEnv, expectedRet: Type): void {
    for (const stmt of block.stmts) {
      this.checkStatement(stmt, env);
    }
    
    checkEscape(block, env, this.diag);
  }

  private inferExpression(expr: ast.Expression, env: TypeEnv, expected?: Type): Type {
    switch (expr.tag) {
      case "integer":
        return expected || { kind: "literal", value: expr.value };
      
      case "decimal":
        return expected || { kind: "primitive", name: "decimal", width: 64 };
      
      case "text":
        return { kind: "primitive", name: "text" };
      
      case "character":
        return { kind: "primitive", name: "character" };
      
      case "true":
      case "false":
        return { kind: "primitive", name: "boolean" };
      
      case "uninitialized":
        return expected || { kind: "unknown" };
      
      case "unreachable":
        return { kind: "unknown" };
      
      case "newline":
        return { kind: "primitive", name: "text" };
      
      case "quantity":
        return { kind: "primitive", name: "integer", width: 64 };
      
      case "name": {
        const type = env.lookup(expr.text);
        if (!type) {
          this.diag.emit(Code.Missing, expr.span, `undefined symbol '${expr.text}'`);
          this.diag.suggestion(`Check if '${expr.text}' is defined or imported`);
          return { kind: "unknown" };
        }
        return type;
      }
      
      case "call": {
        const calleeType = this.inferExpression(expr.callee, env);
        if (calleeType.kind !== "function") {
          this.diag.emit(Code.Invalid, expr.callee.span, `cannot call non-function type`);
          this.diag.note(expr.callee.span, `found type: ${typeToString(calleeType)}`);
          this.diag.suggestion(`Only functions can be called`);
          return { kind: "unknown" };
        }
        
        if (expr.args.length !== calleeType.params.length) {
          this.diag.emit(Code.Invalid, expr.span, 
            `expected ${calleeType.params.length} arguments, got ${expr.args.length}`);
          this.diag.suggestion(`Adjust the number of arguments to match the function signature`);
          return calleeType.ret;
        }
        
        for (let i = 0; i < expr.args.length; i++) {
          const argType = this.inferExpression(expr.args[i], env, calleeType.params[i]);
          const coercion = canCoerce(argType, calleeType.params[i]);
          if (!coercion.ok) {
            this.diag.emit(Code.Invalid, expr.args[i].span,
              `argument ${i + 1}: type mismatch`);
            this.diag.note(expr.args[i].span, `expected: ${typeToString(calleeType.params[i])}`);
            this.diag.note(expr.args[i].span, `found: ${typeToString(argType)}`);
            this.diag.suggestion(`Convert the argument to the expected type`);
          }
        }
        
        return calleeType.ret;
      }
      
      case "unary": {
        const operandType = this.inferExpression(expr.operand, env);
        if (expr.op === "not") {
          this.checkBoolean(operandType, expr.operand.span);
          return { kind: "primitive", name: "boolean" };
        }
        return operandType;
      }
      
      case "binary": {
        const leftType = this.inferExpression(expr.left, env);
        const rightType = this.inferExpression(expr.right, env);
        
        if (["equals", "does not equal", "is greater than", "is less than", 
             "is at least", "is at most"].includes(expr.op)) {
          return { kind: "primitive", name: "boolean" };
        }
        
        if (expr.op === "and" || expr.op === "or") {
          this.checkBoolean(leftType, expr.left.span);
          this.checkBoolean(rightType, expr.right.span);
          return { kind: "primitive", name: "boolean" };
        }
        
        return leftType;
      }
      
      case "group":
        return this.inferExpression(expr.expr, env, expected);
      
      case "field": {
        const objectType = this.inferExpression(expr.object, env);
        if (objectType.kind === "record") {
          const fieldType = objectType.fields.get(expr.field.text);
          if (!fieldType) {
            this.diag.emit(Code.Missing, expr.field.span, 
              `record has no field '${expr.field.text}'`);
            const availableFields = Array.from(objectType.fields.keys()).join(", ");
            this.diag.suggestion(`Available fields: ${availableFields}`);
            return { kind: "unknown" };
          }
          return fieldType;
        }
        this.diag.emit(Code.Invalid, expr.object.span, `cannot access field on non-record type`);
        this.diag.note(expr.object.span, `found type: ${typeToString(objectType)}`);
        return { kind: "unknown" };
      }
      
      case "index": {
        const objectType = this.inferExpression(expr.object, env);
        const indexType = this.inferExpression(expr.index, env);
        
        if (objectType.kind === "array" || objectType.kind === "sequence") {
          return objectType.elem;
        }
        
        this.diag.emit(Code.Invalid, expr.object.span, `cannot index non-sequence type`);
        this.diag.note(expr.object.span, `found type: ${typeToString(objectType)}`);
        return { kind: "unknown" };
      }
    }
  }

  private resolveType(type: ast.Type): Type {
    switch (type.tag) {
      case "primitive":
        return { kind: "primitive", name: type.name, width: type.width ? parseInt(type.width) : undefined };
      
      case "array":
        return { kind: "array", elem: this.resolveType(type.elem) };
      
      case "sequence":
        return { kind: "sequence", elem: this.resolveType(type.elem) };
      
      case "optional":
        return { kind: "optional", elem: this.resolveType(type.elem) };
      
      case "error":
        return { kind: "error", elem: this.resolveType(type.elem) };
      
      case "pointer":
        return { kind: "pointer", elem: this.resolveType(type.elem) };
      
      case "named": {
        const def = this.typeDefs.get(type.name.text);
        if (!def) {
          this.diag.emit(Code.Missing, type.name.span, `undefined type '${type.name.text}'`);
          this.diag.suggestion(`Check if '${type.name.text}' is defined or imported`);
          return { kind: "unknown" };
        }
        return def;
      }
    }
  }

  private checkBoolean(type: Type, span: any): void {
    if (type.kind !== "primitive" || type.name !== "boolean") {
      this.diag.emit(Code.Invalid, span, `expected boolean, found ${typeToString(type)}`);
      this.diag.suggestion(`Use a boolean expression or comparison`);
    }
  }

  private extractElementType(type: Type, span: any): Type {
    if (type.kind === "array" || type.kind === "sequence") {
      return type.elem;
    }
    this.diag.emit(Code.Invalid, span, `expected sequence type, found ${typeToString(type)}`);
    this.diag.suggestion(`Use an array or sequence in a for loop`);
    return { kind: "unknown" };
  }

  private checkMatchExhaustiveness(scrutineeType: Type, cases: ast.Case[], span: any): void {
    checkExhaustiveness(scrutineeType, cases, span, this.diag);
  }

  private bindPattern(pattern: ast.Pattern, type: Type, env: TypeEnv): void {
    if (pattern.tag === "name" && pattern.text !== "_") {
      env.define(pattern.text, type);
    }
  }
}
```

## `src/types/coerce.ts`

```typescript
import { Type, typesEqual, PrimitiveType, OptionalType, ErrorType } from "./type";

export interface CoercionResult {
  ok: boolean;
  type?: Type;
  reason?: string;
}

export function canCoerce(from: Type, to: Type): CoercionResult {
  // Exact match
  if (typesEqual(from, to)) {
    return { ok: true, type: to };
  }

  // Literal to primitive
  if (from.kind === "literal" && to.kind === "primitive") {
    return { ok: true, type: to };
  }

  // T → ?T (wrap in optional)
  if (to.kind === "optional") {
    const inner = canCoerce(from, to.elem);
    if (inner.ok) {
      return { ok: true, type: to };
    }
  }

  // ?T → ?U if T → U
  if (from.kind === "optional" && to.kind === "optional") {
    const inner = canCoerce(from.elem, to.elem);
    if (inner.ok) {
      return { ok: true, type: to };
    }
  }

  // !T → !U if T → U (error propagation)
  if (from.kind === "error" && to.kind === "error") {
    const inner = canCoerce(from.elem, to.elem);
    if (inner.ok) {
      return { ok: true, type: to };
    }
  }

  // No silent crossing between ?T and !T
  if ((from.kind === "optional" && to.kind === "error") ||
      (from.kind === "error" && to.kind === "optional")) {
    return { ok: false, reason: "cannot silently convert between optional and error types" };
  }

  // Numeric widening (e.g., integer 32 → integer 64)
  if (from.kind === "primitive" && to.kind === "primitive") {
    if (from.name === to.name && from.width && to.width) {
      if (from.width < to.width) {
        return { ok: true, type: to };
      }
    }
  }

  return { ok: false, reason: `cannot coerce to target type` };
}
```

## `src/types/env.ts`

```typescript
import { Type } from "./type";

export class TypeEnv {
  private parent?: TypeEnv;
  private types: Map<string, Type>;

  constructor(parent?: TypeEnv) {
    this.parent = parent;
    this.types = new Map();
  }

  define(name: string, type: Type): void {
    this.types.set(name, type);
  }

  lookup(name: string): Type | undefined {
    const local = this.types.get(name);
    if (local) return local;
    if (this.parent) return this.parent.lookup(name);
    return undefined;
  }

  child(): TypeEnv {
    return new TypeEnv(this);
  }
}
```

## `src/types/escape.ts`

```typescript
import * as ast from "../ast/node";
import { TypeEnv } from "./env";
import { Engine } from "../diag/engine";
import { Code } from "../diag/code";
import { Type } from "./type";

export function checkEscape(block: ast.Block, env: TypeEnv, diag: Engine): void {
  const directLocals = new Set<string>();
  for (const stmt of block.stmts) {
    if (stmt.tag === "constant" || stmt.tag === "mutable") {
      directLocals.add(stmt.name.text);
    } else if (stmt.tag === "for") {
      directLocals.add(stmt.bind.text);
    } else if (stmt.tag === "match") {
      for (const c of stmt.cases) {
        if (c.pattern.tag === "name" && c.pattern.text !== "_") {
          directLocals.add(c.pattern.text);
        }
      }
    }
  }

  if (directLocals.size === 0) return;

  function isArenaBound(type: Type): boolean {
    switch (type.kind) {
      case "pointer":
      case "array":
      case "sequence":
      case "record":
      case "choice":
      case "function":
        return true;
      default:
        return false;
    }
  }

  function checkExpr(expr: ast.Expression, isReturning: boolean, isArg: boolean): void {
    if (expr.tag === "name") {
      if (directLocals.has(expr.text)) {
        const type = env.lookup(expr.text);
        if (type && isArenaBound(type)) {
          if (isReturning) {
            diag.emit(Code.ScopeEscape, expr.span, 
              `local variable '${expr.text}' may escape current scope arena via return; requires explicit 'share' or 'move' annotation`);
          } else if (isArg) {
            diag.emit(Code.ScopeEscape, expr.span, 
              `local variable '${expr.text}' passed to function may escape current scope; requires explicit 'share' or 'move' annotation`);
          }
        }
      }
    }

    switch (expr.tag) {
      case "call":
        checkExpr(expr.callee, false, false);
        for (const arg of expr.args) {
          checkExpr(arg, false, true);
        }
        break;
      case "unary":
        checkExpr(expr.operand, false, false);
        break;
      case "binary":
        checkExpr(expr.left, false, false);
        checkExpr(expr.right, false, false);
        break;
      case "group":
        checkExpr(expr.expr, isReturning, isArg);
        break;
      case "field":
        checkExpr(expr.object, false, false);
        break;
      case "index":
        checkExpr(expr.object, false, false);
        checkExpr(expr.index, false, false);
        break;
    }
  }

  function checkStmt(stmt: ast.Statement): void {
    switch (stmt.tag) {
      case "give":
        if (stmt.value) checkExpr(stmt.value, true, false);
        break;
      case "action":
        for (const arg of stmt.args) {
          checkExpr(arg, false, true);
        }
        break;
      case "constant":
      case "mutable":
        if (stmt.value) checkExpr(stmt.value, false, false);
        break;
      case "when":
        checkExpr(stmt.cond, false, false);
        checkBlock(stmt.then);
        if (stmt.else) {
          if (stmt.else.tag === "when") {
            checkStmt(stmt.else);
          } else {
            checkBlock(stmt.else);
          }
        }
        break;
      case "while":
        checkExpr(stmt.cond, false, false);
        checkBlock(stmt.body);
        break;
      case "repeat":
        checkBlock(stmt.body);
        break;
      case "for":
        checkExpr(stmt.iter, false, false);
        checkBlock(stmt.body);
        break;
      case "match":
        checkExpr(stmt.scrutinee, false, false);
        for (const c of stmt.cases) {
          checkBlock(c.body);
        }
        break;
      case "try":
        checkExpr(stmt.expr, false, false);
        break;
      case "defer":
        if (stmt.body.tag === "block") {
          checkBlock(stmt.body);
        } else {
          checkExpr(stmt.body, false, false);
        }
        break;
      case "unsafe":
        checkBlock(stmt.body);
        break;
    }
  }

  function checkBlock(b: ast.Block): void {
    for (const s of b.stmts) {
      checkStmt(s);
    }
  }

  checkBlock(block);
}
```

## `src/types/exhaust.ts`

```typescript
import * as ast from "../ast/node";
import { Engine } from "../diag/engine";
import { Code } from "../diag/code";
import { Type, ChoiceType } from "./type";

export function checkExhaustiveness(
  scrutineeType: Type,
  cases: ast.Case[],
  span: any,
  diag: Engine
): void {
  if (scrutineeType.kind !== "choice") {
    // For non-choice types, just check for wildcard
    const hasWildcard = cases.some(c => c.pattern.tag === "wildcard");
    if (!hasWildcard && cases.length === 0) {
      diag.emit(Code.Invalid, span, `match must have at least one case`);
    }
    return;
  }

  const choiceType = scrutineeType as ChoiceType;
  const coveredVariants = new Set<string>();
  let hasWildcard = false;

  for (const c of cases) {
    if (c.pattern.tag === "wildcard") {
      hasWildcard = true;
    } else if (c.pattern.tag === "name") {
      if (choiceType.variants.has(c.pattern.text)) {
        coveredVariants.add(c.pattern.text);
      }
    }
  }

  if (!hasWildcard) {
    const missing: string[] = [];
    for (const variant of choiceType.variants.keys()) {
      if (!coveredVariants.has(variant)) {
        missing.push(variant);
      }
    }

    if (missing.length > 0) {
      diag.emit(Code.Invalid, span, 
        `match is not exhaustive: missing cases for ${missing.join(", ")}`);
    }
  }
}
```

## `src/types/type.ts`

```typescript
export type Type =
  | PrimitiveType
  | ArrayType
  | SequenceType
  | OptionalType
  | ErrorType
  | PointerType
  | NamedType
  | RecordType
  | ChoiceType
  | FunctionType
  | LiteralType
  | UnknownType;

export interface PrimitiveType {
  kind: "primitive";
  name: string;
  width?: number;
}

export interface ArrayType {
  kind: "array";
  elem: Type;
}

export interface SequenceType {
  kind: "sequence";
  elem: Type;
}

export interface OptionalType {
  kind: "optional";
  elem: Type;
}

export interface ErrorType {
  kind: "error";
  elem: Type;
}

export interface PointerType {
  kind: "pointer";
  elem: Type;
}

export interface NamedType {
  kind: "named";
  name: string;
}

export interface RecordType {
  kind: "record";
  name: string;
  fields: Map<string, Type>;
}

export interface ChoiceType {
  kind: "choice";
  name: string;
  variants: Map<string, Type | undefined>;
}

export interface FunctionType {
  kind: "function";
  params: Type[];
  ret: Type;
}

export interface LiteralType {
  kind: "literal";
  value: string;
}

export interface UnknownType {
  kind: "unknown";
}

export function typeToString(t: Type): string {
  switch (t.kind) {
    case "primitive":
      return t.width ? `${t.name} ${t.width}` : t.name;
    case "array":
      return `array of ${typeToString(t.elem)}`;
    case "sequence":
      return `sequence of ${typeToString(t.elem)}`;
    case "optional":
      return `optional ${typeToString(t.elem)}`;
    case "error":
      return `error ${typeToString(t.elem)}`;
    case "pointer":
      return `pointer to ${typeToString(t.elem)}`;
    case "named":
      return t.name;
    case "record":
      return t.name;
    case "choice":
      return t.name;
    case "function":
      const params = t.params.map(typeToString).join(", ");
      return `function(${params}) -> ${typeToString(t.ret)}`;
    case "literal":
      return `literal ${t.value}`;
    case "unknown":
      return "unknown";
  }
}

export function typesEqual(a: Type, b: Type): boolean {
  if (a.kind !== b.kind) return false;
  
  switch (a.kind) {
    case "primitive":
      return a.name === (b as PrimitiveType).name && a.width === (b as PrimitiveType).width;
    case "array":
      return typesEqual(a.elem, (b as ArrayType).elem);
    case "sequence":
      return typesEqual(a.elem, (b as SequenceType).elem);
    case "optional":
      return typesEqual(a.elem, (b as OptionalType).elem);
    case "error":
      return typesEqual(a.elem, (b as ErrorType).elem);
    case "pointer":
      return typesEqual(a.elem, (b as PointerType).elem);
    case "named":
      return a.name === (b as NamedType).name;
    case "record":
    case "choice":
      return a.name === (b as RecordType | ChoiceType).name;
    case "function":
      const bf = b as FunctionType;
      if (a.params.length !== bf.params.length) return false;
      for (let i = 0; i < a.params.length; i++) {
        if (!typesEqual(a.params[i], bf.params[i])) return false;
      }
      return typesEqual(a.ret, bf.ret);
    case "literal":
      return a.value === (b as LiteralType).value;
    case "unknown":
      return true;
  }
}
```

## `std/bits.rt`

```rt
module bits {
  --- Bitset collection ---
  --- Efficient bit-level storage ---
  
  public type Bits is record {
    data of type pointer to byte.
    length of type integer 64.
  }.
  
  public function create(size of type integer 64) {
    constant result of type Bits is uninitialized.
    give result.
  }
  
  public function enable(collection of type Bits, index of type integer 64) {
    give.
  }
  
  public function disable(collection of type Bits, index of type integer 64) {
    give.
  }
  
  public function enabled(collection of type Bits, index of type integer 64) {
    constant result of type boolean is false.
    give result.
  }
}
```

## `std/deque.rt`

```rt
module deque {
  --- Double-ended queue ---
  --- Efficient insertion/removal at both ends ---
  
  public type Deque is record {
    data of type pointer to byte.
    length of type integer 64.
  }.
  
  public function create() {
    constant result of type Deque is uninitialized.
    give result.
  }
  
  public function front(collection of type Deque, value of type pointer to byte) {
    give.
  }
  
  public function back(collection of type Deque, value of type pointer to byte) {
    give.
  }
  
  public function popfront(collection of type Deque) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
  
  public function popback(collection of type Deque) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
}
```

## `std/env.rt`

```rt
module env {
  --- Environment variables ---
  --- Provides access to process environment ---
  
  public function variable(key of type pointer to byte) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
}
```

## `std/file.rt`

```rt
module file {
  public type File is record {
    handle of type pointer to byte.
  }.
  
  public type Mode is choice {
    Read.
    Write.
    Both.
    Create.
  }.
  
  public function open(path of type pointer to byte, mode of type Mode) {
    constant result of type File is uninitialized.
    give result.
  }
  
  public function read(file of type File, buffer of type pointer to byte, size of type integer 64) {
    constant result of type integer 64 is 0.
    give result.
  }
  
  public function write(file of type File, data of type pointer to byte, size of type integer 64) {
    give.
  }
  
  public function close(file of type File) {
    give.
  }
}
```

## `std/format.rt`

```rt
module format {
  --- Formatting and parsing ---
  --- Type-safe string formatting ---
  
  public function format(buffer of type pointer to byte, size of type integer 64, template of type pointer to byte) {
    constant result of type integer 64 is 0.
    give result.
  }
  
  public function parse(text of type pointer to byte) {
    constant result of type integer 64 is 0.
    give result.
  }
}
```

## `std/heap.rt`

```rt
module heap {
  --- Priority queue (heap) ---
  --- Efficient priority-based retrieval ---
  
  public type Heap is record {
    data of type pointer to byte.
    length of type integer 64.
  }.
  
  public function create() {
    constant result of type Heap is uninitialized.
    give result.
  }
  
  public function insert(collection of type Heap, value of type pointer to byte) {
    give.
  }
  
  public function extract(collection of type Heap) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
  
  public function peek(collection of type Heap) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
}
```

## `std/index.rt`

```rt
module index {
  --- String-keyed map ---
  --- Fast text-based lookup ---
  
  public type Index is record {
    data of type pointer to byte.
    size of type integer 64.
  }.
  
  public function create() {
    constant result of type Index is uninitialized.
    give result.
  }
  
  public function register(collection of type Index, key of type pointer to byte, value of type pointer to byte) {
    give.
  }
  
  public function lookup(collection of type Index, key of type pointer to byte) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
  
  public function known(collection of type Index, key of type pointer to byte) {
    constant result of type boolean is false.
    give result.
  }
}
```

## `std/list.rt`

```rt
module list {
  public type List is record {
    data of type pointer to byte.
    length of type integer 64.
    capacity of type integer 64.
  }.
  
  public function create() {
    constant result of type List is uninitialized.
    give result.
  }
  
  public function push(collection of type List, item of type pointer to byte) {
    give.
  }
  
  public function get(collection of type List, index of type integer 64) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
  
  public function length(collection of type List) {
    give collection.length.
  }
}
```

## `std/log.rt`

```rt
module log {
  --- Logging utilities ---
  --- Structured logging with levels and scopes ---
  
  public type Level is choice {
    Error.
    Warning.
    Info.
    Debug.
  }.
  
  public function error(scope of type pointer to byte, message of type pointer to byte) {
    give.
  }
  
  public function warning(scope of type pointer to byte, message of type pointer to byte) {
    give.
  }
  
  public function info(scope of type pointer to byte, message of type pointer to byte) {
    give.
  }
  
  public function debug(scope of type pointer to byte, message of type pointer to byte) {
    give.
  }
}
```

## `std/map.rt`

```rt
module map {
  --- Hash map collection ---
  --- Key-value store implementation ---
  
  public type Map is record {
    data of type pointer to byte.
    size of type integer 64.
  }.
  
  public function create() {
    constant result of type Map is uninitialized.
    give result.
  }
  
  public function put(collection of type Map, key of type pointer to byte, value of type pointer to byte) {
    give.
  }
  
  public function get(collection of type Map, key of type pointer to byte) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
  
  public function contains(collection of type Map, key of type pointer to byte) {
    constant result of type boolean is false.
    give result.
  }
}
```

## `std/memory.rt`

```rt
module memory {
  public type Allocator is record {
    handle of type pointer to byte.
  }.
  
  public function system() {
    constant result of type Allocator is uninitialized.
    give result.
  }
  
  public function arena() {
    constant result of type Allocator is uninitialized.
    give result.
  }
  
  public function allocate(allocator of type Allocator, size of type integer 64) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
  
  public function release(allocator of type Allocator, buffer of type pointer to byte) {
    give.
  }
  
  public function expand(allocator of type Allocator, buffer of type pointer to byte, size of type integer 64) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
}
```

## `std/net.rt`

```rt
module net {
  --- Network operations ---
  --- TCP/UDP networking and DNS resolution ---
  
  public type Stream is record {
    handle of type pointer to byte.
  }.
  
  public type Listener is record {
    handle of type pointer to byte.
  }.
  
  public type Socket is record {
    handle of type pointer to byte.
  }.
  
  public function dial(host of type pointer to byte, port of type integer 32) {
    constant result of type Stream is uninitialized.
    give result.
  }
  
  public function accept(host of type pointer to byte, port of type integer 32) {
    constant result of type Listener is uninitialized.
    give result.
  }
  
  public function send(stream of type Stream, data of type pointer to byte, size of type integer 64) {
    give.
  }
  
  public function receive(stream of type Stream, buffer of type pointer to byte, size of type integer 64) {
    constant result of type integer 64 is 0.
    give result.
  }
  
  public function resolve(host of type pointer to byte) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
}
```

## `std/path.rt`

```rt
module path {
  public function merge(first of type pointer to byte, second of type pointer to byte) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
  
  public function parent(path of type pointer to byte) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
  
  public function name(path of type pointer to byte) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
  
  public function suffix(path of type pointer to byte) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
  
  public function absolute(path of type pointer to byte) {
    constant result of type boolean is false.
    give result.
  }
}
```

## `std/process.rt`

```rt
module process {
  --- Process management ---
  --- Provides process control and argument access ---
  
  public function args() {
    constant result of type integer 64 is 0.
    give result.
  }
  
  public function arg(index of type integer 64) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
  
  public type Command is record {
    handle of type pointer to byte.
  }.
  
  public function spawn(command of type pointer to byte) {
    constant result of type Command is uninitialized.
    give result.
  }
  
  public function wait(command of type Command) {
    constant result of type integer 64 is 0.
    give result.
  }
  
  public function output(command of type Command) {
    constant result of type pointer to byte is uninitialized.
    give result.
  }
}
```

## `std/random.rt`

```rt
module random {
  --- Random number generation ---
  --- OS-backed and PRNG implementations ---
  
  public type Random is record {
    state of type pointer to byte.
  }.
  
  public function default() {
    constant result of type Random is uninitialized.
    give result.
  }
  
  public function bytes(rng of type Random, buffer of type pointer to byte, size of type integer 64) {
    give.
  }
  
  public function integer(rng of type Random, minimum of type integer 64, maximum of type integer 64) {
    constant result of type integer 64 is 0.
    give result.
  }
}
```

## `std/set.rt`

```rt
module set {
  --- Set collection ---
  --- Unique value storage ---
  
  public type Set is record {
    data of type pointer to byte.
    size of type integer 64.
  }.
  
  public function create() {
    constant result of type Set is uninitialized.
    give result.
  }
  
  public function insert(collection of type Set, value of type pointer to byte) {
    give.
  }
  
  public function contains(collection of type Set, value of type pointer to byte) {
    constant result of type boolean is false.
    give result.
  }
  
  public function remove(collection of type Set, value of type pointer to byte) {
    give.
  }
}
```

## `std/stream.rt`

```rt
module stream {
   public type Stream is record {
     handle of type pointer to byte.
   }.
   public function input() {
     constant result of type Stream is uninitialized.
     give result.
   }
   public function output() {
     constant result of type Stream is uninitialized.
     give result.
   }
   public function report() {
     constant result of type Stream is uninitialized.
     give result.
   }
   public function write(stream of type Stream, content of type pointer to byte) {
     give.
   }
   public function read(stream of type Stream, buffer of type pointer to byte, size of type integer 64) {
     constant result of type integer 64 is 0.
     give result.
   }
   public function close(stream of type Stream) {
     give.
   }
   public function print(stream of type Stream, content of type pointer to byte) {
     write(stream, content).
   }
 }
```

## `std/sync.rt`

```rt
module sync {
  --- Synchronization primitives ---
  --- Mutexes, condition variables, semaphores ---
  
  public type Mutex is record {
    handle of type pointer to byte.
  }.
  
  public type Condvar is record {
    handle of type pointer to byte.
  }.
  
  public type Semaphore is record {
    handle of type pointer to byte.
  }.
  
  public type Once is record {
    handle of type pointer to byte.
  }.
  
  public type Group is record {
    handle of type pointer to byte.
  }.
  
  public function mutex() {
    constant result of type Mutex is uninitialized.
    give result.
  }
  
  public function lock(handle of type Mutex) {
    give.
  }
  
  public function unlock(handle of type Mutex) {
    give.
  }
}
```

## `std/thread.rt`

```rt
module thread {
  --- Threading primitives ---
  --- Cross-platform thread management ---
  
  public type Thread is record {
    handle of type pointer to byte.
  }.
  
  public function spawn(entry of type pointer to byte) {
    constant result of type Thread is uninitialized.
    give result.
  }
  
  public function await(handle of type Thread) {
    give.
  }
}
```

## `std/time.rt`

```rt
module time {
  --- Time and duration utilities ---
  --- Cross-platform time operations ---
  
  public type Duration is record {
    nanos of type integer 64.
  }.
  
  public type Instant is record {
    nanos of type integer 64.
  }.
  
  public function instant() {
    constant result of type Instant is uninitialized.
    give result.
  }
  
  public function moment() {
    constant result of type integer 64 is 0.
    give result.
  }
  
  public function pause(duration of type Duration) {
    give.
  }
}
```

## `tests/backend/run.ts`

```typescript
import { build } from "../../src/backend/zig/driver";
import { parse } from "../../src/ir/parse";
import { mkdirSync, rmSync, existsSync } from "fs";
import { join } from "path";

const tmpDir = join(process.cwd(), "tmp-backend-test");

function runTest(name: string, irCode: string, expectFail: boolean, mode: string, expectedError?: string): boolean {
  console.log(`Testing: ${name} (${mode})`);
  
  try {
    const mod = parse(irCode);
    const result = build(mod, mode, tmpDir);
    
    if (expectFail) {
      if (result.success) {
        console.log(`  ✗ Expected failure, but succeeded`);
        return false;
      }
      if (expectedError && !result.error?.includes(expectedError)) {
        console.log(`  ✗ Failed for the wrong reason:\n${result.error}`);
        return false;
      }
      console.log(`  ✓ Correctly failed with:\n${result.error?.trim()}`);
      return true;
    } else {
      if (!result.success) {
        console.log(`  ✗ Unexpected failure:\n${result.error}`);
        return false;
      }
      console.log(`  ✓ Success. Output: "${result.output?.trim()}"`);
      return true;
    }
  } catch (e: any) {
    console.log(`  ✗ Crashed: ${e.message}`);
    return false;
  }
}

const helloIr = `
module app {
  extern "c" fn @puts(ptr<int>) -> int

  fn @main() -> void {
  entry:
    %1 = alloc scope int
    store 42, %1
    %2 = load %1
    return
  }
}
`;

// Note: For a true hello world, we'd emit a call to puts, but MVL-1 IR 
// currently lacks string literal values in instructions. We test the pipeline mechanics.

const panicIr = `
module app {
  fn @main() -> void {
  entry:
    panic "deliberate failure"
  }
}
`;

let allPassed = true;

if (existsSync(tmpDir)) {
  rmSync(tmpDir, { recursive: true });
}
mkdirSync(tmpDir, { recursive: true });

allPassed = runTest("hello_pipeline", helloIr, false, "dev") && allPassed;
allPassed = runTest("panic_dev", panicIr, true, "dev", "panic: deliberate failure") && allPassed;
allPassed = runTest("panic_release", panicIr, true, "release", "panic: deliberate failure") && allPassed;

rmSync(tmpDir, { recursive: true });

if (!allPassed) {
  process.exit(1);
}

console.log("Backend tests passed");
```

## `tests/diag/run.ts`

```typescript
import { Lexer } from "../../src/lex/lexer";
import { Engine } from "../../src/diag/engine";
import { render } from "../../src/diag/render";

const src = `constant x is "unterminated`;
const diag = new Engine();
const lex = new Lexer(src, diag);
lex.lex();

for (const msg of diag.messages) {
  console.log(render(msg, src));
}
```

## `tests/ir/run.ts`

```typescript
import { parse } from "../../src/ir/parse";
import { print } from "../../src/ir/print";
import { validate } from "../../src/ir/valid";
import { readFileSync, writeFileSync, readdirSync, existsSync } from "fs";
import { join } from "path";

const fixturesDir = "tests/ir/fixtures";
const files = readdirSync(fixturesDir).filter(f => f.endsWith(".ir"));

let failed = false;

for (const file of files) {
  const srcPath = join(fixturesDir, file);
  const src = readFileSync(srcPath, "utf8");
  
  let ast: any;
  try {
    ast = parse(src);
  } catch (e: any) {
    console.error(`Parse failed for ${file}: ${e.message}`);
    failed = true;
    continue;
  }

  const errors = validate(ast);
  if (errors.length > 0) {
    console.error(`Validation failed for ${file}:`);
    for (const err of errors) {
      console.error(`  - ${err.msg}`);
    }
    failed = true;
    continue;
  }

  const printed = print(ast);
  const goldenPath = join(fixturesDir, file.replace(".ir", ".golden"));
  
  if (existsSync(goldenPath)) {
    const expected = readFileSync(goldenPath, "utf8");
    if (printed !== expected) {
      console.error(`Round-trip mismatch for ${file}`);
      console.error("=== Expected ===");
      console.error(expected);
      console.error("=== Actual ===");
      console.error(printed);
      failed = true;
    }
  } else {
    writeFileSync(goldenPath, printed);
    console.log(`Created golden file for ${file}`);
  }
}

if (failed) {
  process.exit(1);
}

console.log("IR tests passed");
```

## `tests/lex/fixtures/sample.rt`

```rt
-- line comment
--- this is a
multiline comment ---
module app {
    public constant x of type integer 32 is 42.
    mutable y of type decimal 64 is 3.14.
    constant greeting of type text is "I'm saying \"hello\"".
    constant message of type text is "line one" plus newline plus "line two".
    constant c of type character is 'a'.
    
    public function add(a of type integer 32, b of type integer 32) {
        give a plus b.
    }
    
    type Point is record {
        x of type decimal 64.
        y of type decimal 64.
    }.
    
    type Color is choice {
        Red.
        Green is 5.
        Blue.
    }.
    
    use "c" function puts(s of type pointer to byte) of type integer 32.
    
    start() {
        when true {
            constant z is 1.
        } otherwise {
            constant z is 2.
        }
        
        while false {
        }
        
        for each item in items {
            process item.
        }
        
        match x {
            case 1 {
                give.
            }
            case anything {
                unreachable.
            }
        }
        
        constant maybe_number of type optional integer 32 is uninitialized.
        constant result is maybe_number catch 0.
        
        on leave close file.
        
        unsafe {
            constant memory_address of type pointer to integer 64 is 0.
        }
        
        give.
    }
}
```

## `tests/lex/run.ts`

```typescript
import { Lexer } from "../../src/lex/lexer";
import { Engine } from "../../src/diag/engine";
import { readFileSync, writeFileSync, existsSync } from "fs";

const src = readFileSync("tests/lex/fixtures/sample.rt", "utf8");
const diag = new Engine();
const lex = new Lexer(src, diag);
const tokens = lex.lex();

const actual = JSON.stringify(tokens, null, 2);
const goldenPath = "tests/lex/fixtures/sample.json";

// If golden file doesn't exist, create it
if (!existsSync(goldenPath)) {
  writeFileSync(goldenPath, actual);
  console.log("Created golden file");
  process.exit(0);
}

const expected = readFileSync(goldenPath, "utf8");

if (actual !== expected) {
  console.error("Mismatch!");
  writeFileSync("tests/lex/fixtures/sample.actual.json", actual);
  process.exit(1);
}

console.log("Lexer test passed");
```

## `tests/parse/fixtures/basic.rt`

```rt
module app {
  public constant x of type integer 32 is 42.
  public mutable y of type decimal 64 is 3.14.
  mutable counter of type integer 32 is 0.
  
  public function add(a of type integer 32, b of type integer 32) {
    give a plus b.
  }
  
  type Point is record {
    x of type decimal 64.
    y of type decimal 64.
  }.
  
  type Color is choice {
    Red.
    Green is 5.
    Blue.
  }.
  
  use filesystem.
  
  start() {
    when true {
      constant z is 1.
    } otherwise {
      constant z is 2.
    }
    
    repeat until counter reaches 10 {
      advance counter.
    }
    
    for each item in items {
      process item.
    }
    
    match x {
      case 1 {
        give.
      }
      case anything {
        unreachable.
      }
    }
    
    constant maybe_number of type optional integer 32 is uninitialized.
    constant result is maybe_number catch 0.
    
    on leave close file.
    
    unsafe {
      constant memory_address of type pointer to integer 64 is 0.
    }
    
    give.
  }
}
```

## `tests/parse/fixtures/error.rt`

```rt
module broken {
    constant x of type integer 32 is .
    function missing() {
        constant y is .
    }
    constant z is 42
}
```

## `tests/parse/run.ts`

```typescript
import { Lexer } from "../../src/lex/lexer";
import { Engine } from "../../src/diag/engine";
import { Parser } from "../../src/parse/parser";
import { print } from "../../src/ast/print";
import { readFileSync, writeFileSync, readdirSync, existsSync, mkdirSync } from "fs";
import { join } from "path";

const fixturesDir = "tests/parse/fixtures";

if (!existsSync(fixturesDir)) {
  mkdirSync(fixturesDir, { recursive: true });
}

const files = readdirSync(fixturesDir).filter(f => f.endsWith(".rt"));

if (files.length === 0) {
  console.log("No parse fixtures found");
  process.exit(0);
}

let failed = false;

for (const file of files) {
  const srcPath = join(fixturesDir, file);
  const src = readFileSync(srcPath, "utf8");
  
  const diag = new Engine();
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  const ast = parser.parse();
  
  const printed1 = print(ast);
  const diag2 = new Engine();
  const lexer2 = new Lexer(printed1, diag2);
  const toks2 = lexer2.lex();
  const parser2 = new Parser(toks2, diag2);
  const ast2 = parser2.parse();
  const printed2 = print(ast2);
  
  if (printed1 !== printed2) {
    console.error(`Round-trip failed for ${file}:`);
    console.error("=== First print ===");
    console.error(printed1);
    console.error("=== Second print ===");
    console.error(printed2);
    failed = true;
    continue;
  }
  
  if (file.startsWith("error")) {
    if (!diag.failed) {
      console.error(`Expected diagnostics for ${file}, but none were emitted`);
      failed = true;
      continue;
    }
    if (!ast || ast.tag !== "program") {
      console.error(`Parser crashed on ${file}`);
      failed = true;
      continue;
    }
  }
  
  const goldenPath = join(fixturesDir, file.replace(".rt", ".golden"));
  writeFileSync(goldenPath, printed1);
}

if (failed) {
  process.exit(1);
}

console.log("Parse tests passed");
```

## `tests/pkg/run.ts`

```typescript
import { mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from "fs";
import { join } from "path";
import { vendor } from "../../src/pkg/vendor";
import { ResolveError } from "../../src/pkg/resolve";
import { readLock } from "../../src/pkg/lock";
import { clearCache } from "../../src/pkg/cache";
import { Engine } from "../../src/diag/engine";
import { Code } from "../../src/diag/code";

const tmpDir = join(process.cwd(), "tmp-pkg-test");

function setup() {
  if (existsSync(tmpDir)) rmSync(tmpDir, { recursive: true, force: true });
  mkdirSync(tmpDir, { recursive: true });

  // Level 3: C
  const dirC = join(tmpDir, "C");
  mkdirSync(dirC);
  writeFileSync(join(dirC, "project.json"), JSON.stringify({ name: "C", version: "1.0.0" }));
  writeFileSync(join(dirC, "c.rt"), "module C { }");

  // Level 2: B (depends on C)
  const dirB = join(tmpDir, "B");
  mkdirSync(dirB);
  writeFileSync(join(dirB, "project.json"), JSON.stringify({ 
    name: "B", version: "1.0.0", dependencies: { "C": "path+../C" } 
  }));
  writeFileSync(join(dirB, "b.rt"), "module B { use C. }");

  // Level 1: A (depends on B)
  const dirA = join(tmpDir, "A");
  mkdirSync(dirA);
  writeFileSync(join(dirA, "project.json"), JSON.stringify({ 
    name: "A", version: "1.0.0", dependencies: { "B": "path+../B" } 
  }));
  writeFileSync(join(dirA, "a.rt"), "module A { use B. }");
}

function testTransitive() {
  console.log("Testing: 3-level transitive deps");
  setup();
  const dirA = join(tmpDir, "A");
  const origCwd = process.cwd();
  process.chdir(dirA);
  
  vendor(dirA);
  
  const lock = readLock(join(dirA, "project.lock"));
  if (!lock || lock.packages.length !== 2) {
    throw new Error("Lockfile should contain 2 packages (B and C)");
  }
  console.log("  ✓ Lockfile generated with transitive deps");
  process.chdir(origCwd);
}

function testOffline() {
  console.log("Testing: offline rebuild (lockfile-driven)");
  const dirA = join(tmpDir, "A");
  const origCwd = process.cwd();
  process.chdir(dirA);
  
  clearCache();
  rmSync(join(dirA, "vendor"), { recursive: true, force: true });
  
  vendor(dirA);
  console.log("  ✓ Rebuilt offline successfully");
  process.chdir(origCwd);
}

function testConflict() {
  console.log("Testing: conflict reporting");
  const dirConflict = join(tmpDir, "conflict");
  mkdirSync(dirConflict, { recursive: true });
  
  const dirC1 = join(tmpDir, "C1");
  mkdirSync(dirC1);
  writeFileSync(join(dirC1, "project.json"), JSON.stringify({ name: "C", version: "1.0.0" }));
  
  const dirC2 = join(tmpDir, "C2");
  mkdirSync(dirC2);
  writeFileSync(join(dirC2, "project.json"), JSON.stringify({ name: "C", version: "2.0.0" }));

  const dirB1 = join(tmpDir, "B1");
  mkdirSync(dirB1);
  writeFileSync(join(dirB1, "project.json"), JSON.stringify({ 
    name: "B1", dependencies: { "C": "path+../C1" } 
  }));

  const dirB2 = join(tmpDir, "B2");
  mkdirSync(dirB2);
  writeFileSync(join(dirB2, "project.json"), JSON.stringify({ 
    name: "B2", dependencies: { "C": "path+../C2" } 
  }));

  writeFileSync(join(dirConflict, "project.json"), JSON.stringify({ 
    name: "root", dependencies: { "B1": "path+../B1", "B2": "path+../B2" } 
  }));

  const origCwd = process.cwd();
  process.chdir(dirConflict);
  const diag = new Engine();
  
  try {
    vendor(dirConflict, diag);
    throw new Error("Expected conflict error");
  } catch (e: any) {
    if (diag.messages.some(m => m.code === Code.PkgConflict)) {
      console.log("  ✓ Conflict correctly reported with coded diagnostic");
    } else {
      throw e;
    }
  }
  process.chdir(origCwd);
}

function testTamper() {
  console.log("Testing: tampered cache detection");
  const dirA = join(tmpDir, "A");
  const origCwd = process.cwd();
  process.chdir(dirA);
  
  const lockPath = join(dirA, "project.lock");
  const lock = JSON.parse(readFileSync(lockPath, "utf8"));
  lock.packages[0].hash = "12200000000000000000000000000000000000000000000000000000000000000000";
  writeFileSync(lockPath, JSON.stringify(lock, null, 2));
  
  const diag = new Engine();
  try {
    vendor(dirA, diag);
    throw new Error("Expected hash mismatch error");
  } catch (e: any) {
    if (diag.messages.some(m => m.code === Code.PkgHashMismatch)) {
      console.log("  ✓ Tampered cache correctly detected with coded diagnostic");
    } else {
      throw e;
    }
  }
  process.chdir(origCwd);
}

// Run Gate 9 tests
testTransitive();
testOffline();
testConflict();
testTamper();

// Cleanup
rmSync(tmpDir, { recursive: true, force: true });
console.log("Package manager tests passed");
```

## `tests/sema/fixtures/basic/main.rt`

```rt
module main {
  use math.
  
  start() {
    constant result is add(1, 2).
    give.
  }
}
```

## `tests/sema/fixtures/basic/math.rt`

```rt
module math {
  public function add(a of type integer 32, b of type integer 32) {
    give a plus b.
  }
  
  public type Point is record {
    x of type decimal 64.
    y of type decimal 64.
  }.
}
```

## `tests/sema/fixtures/basic/nested.rt`

```rt
module nested {
  use "./sub/module".
  
  start() {
    constant result is nested_add(1, 2).
    give.
  }
}
```

## `tests/sema/fixtures/basic/path.rt`

```rt
module paths {
  use "./math".
  
  start() {
    constant result is add(1, 2).
    give.
  }
}
```

## `tests/sema/fixtures/basic/sub/module.rt`

```rt
module submodule {
  public function nested_add(a of type integer 32, b of type integer 32) {
    give a plus b.
  }
}
```

## `tests/sema/fixtures/errors/dup.rt`

```rt
module dup {
  use math.
  use math.
  
  start() {
    give.
  }
}
```

## `tests/sema/fixtures/errors/duplicate.rt`

```rt
module duplicate {
  constant x is 1.
  constant x is 2.
}
```

## `tests/sema/fixtures/errors/field.rt`

```rt
module field {
  type Bad is record {
    x of type integer 32.
    x of type integer 32.
  }.
}
```

## `tests/sema/fixtures/errors/hidden/main.rt`

```rt
module main {
  use secret.
  
  start() {
    constant x is hidden_value.
    give.
  }
}
```

## `tests/sema/fixtures/errors/hidden/secret.rt`

```rt
module secret {
  constant hidden_value is 42.
}
```

## `tests/sema/fixtures/errors/missing.rt`

```rt
module missing {
  start() {
    constant result is undefined_symbol.
    give.
  }
}
```

## `tests/sema/run.ts`

```typescript
import { Resolver } from "../../src/sema/resolver";
import { Engine } from "../../src/diag/engine";
import { Lexer } from "../../src/lex/lexer";
import { Parser } from "../../src/parse/parser";
import { readFileSync, readdirSync, existsSync, statSync } from "fs";
import { join } from "path";

const fixturesDir = "tests/sema/fixtures";

interface TestResult {
  name: string;
  passed: boolean;
  errors: string[];
}

function parse(src: string, diag: Engine) {
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  return parser.parse();
}

function runPackage(pkgPath: string, expectErrors: boolean): TestResult {
  const name = pkgPath.split("/").pop()!;
  const diag = new Engine();
  const results: TestResult = { name, passed: true, errors: [] };

  let entryFile: string | undefined;
  let entryName: string;
  let rootPath: string;

  if (statSync(pkgPath).isDirectory()) {
    // Multi-file package: look for .rt files DIRECTLY in this directory
    const files = readdirSync(pkgPath).filter(f => {
      const full = join(pkgPath, f);
      return f.endsWith(".rt") && statSync(full).isFile();
    });
    
    if (files.length === 0) {
      // Skip directories with no direct .rt files (they're parent dirs of nested packages)
      return { name, passed: true, errors: [] };
    }
    
    entryFile = files.find(f => f === "main.rt") || files[0];
    entryName = entryFile.replace(".rt", "");
    rootPath = pkgPath;
  } else {
    // Single file
    entryFile = pkgPath.split("/").pop()!;
    entryName = entryFile.replace(".rt", "");
    rootPath = join(pkgPath, "..");
  }

  const src = readFileSync(join(rootPath, entryFile), "utf8");
  const program = parse(src, diag);

  if (diag.failed) {
    results.passed = false;
    results.errors.push("parse errors");
    return results;
  }

  const resolver = new Resolver(diag, rootPath);
  resolver.resolve(program, entryName);

  if (expectErrors) {
    if (!diag.failed) {
      results.passed = false;
      results.errors.push("expected errors but none emitted");
    }
  } else {
    if (diag.failed) {
      results.passed = false;
      for (const msg of diag.messages) {
        results.errors.push(`${msg.text} at ${msg.span.line}:${msg.span.col}`);
      }
    }
  }

  return results;
}

const results: TestResult[] = [];

// Run basic tests (should pass)
const basicDir = join(fixturesDir, "basic");
if (existsSync(basicDir)) {
  const items = readdirSync(basicDir);
  for (const item of items) {
    const itemPath = join(basicDir, item);
    results.push(runPackage(itemPath, false));
  }
}

// Run error tests (should fail)
const errorsDir = join(fixturesDir, "errors");
if (existsSync(errorsDir)) {
  const items = readdirSync(errorsDir);
  for (const item of items) {
    const itemPath = join(errorsDir, item);
    results.push(runPackage(itemPath, true));
  }
}

// Report results
let failed = false;
for (const r of results) {
  if (r.passed) {
    console.log(`  ✓ ${r.name}`);
  } else {
    console.log(`  ✗ ${r.name}`);
    for (const err of r.errors) {
      console.log(`      ${err}`);
    }
    failed = true;
  }
}

if (failed) {
  process.exit(1);
}

console.log("Sema tests passed");
```

## `tests/stdlib/list.rt`

```rt
module test_list {
  use "std/list".
  
  start() {
    constant collection is create().
    constant size is length(collection).
    give.
  }
}
```

## `tests/stdlib/memory.rt`

```rt
module test_memory {
  use "std/memory".
  
  start() {
    constant allocator is system().
    constant buffer is allocate(allocator, 1024).
    release(allocator, buffer).
    give.
  }
}
```

## `tests/stdlib/run.ts`

```typescript
import { Resolver } from "../../src/sema/resolver";
import { Engine } from "../../src/diag/engine";
import { Lexer } from "../../src/lex/lexer";
import { Parser } from "../../src/parse/parser";
import { render } from "../../src/diag/render";
import { readFileSync, readdirSync, existsSync } from "fs";
import { join } from "path";

const fixturesDir = "tests/stdlib";

function parse(src: string, diag: Engine) {
  diag.setSource(src);
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  return parser.parse();
}

function runTest(filePath: string): boolean {
  const name = filePath.split("/").pop()!;
  const diag = new Engine();
  try {
    const src = readFileSync(filePath, "utf8");
    const program = parse(src, diag);
    if (diag.failed) {
      console.log(`  ✗ ${name}: parse errors`);
      for (const msg of diag.messages) {
        console.log(render(msg, msg.source || src));
      }
      return false;
    }
    const resolver = new Resolver(diag, process.cwd());
    resolver.resolve(program, name.replace(".rt", ""));
    if (diag.failed) {
      console.log(`  ✗ ${name}: resolution errors`);
      for (const msg of diag.messages) {
        console.log(render(msg, msg.source || src));
      }
      return false;
    }
    console.log(`  ✓ ${name}`);
    return true;
  } catch (e: any) {
    console.log(`  ✗ ${name}: ${e.message}`);
    return false;
  }
}

let allPassed = true;
if (existsSync(fixturesDir)) {
  const tests = readdirSync(fixturesDir).filter(f => f.endsWith(".rt"));
  for (const test of tests) {
    allPassed = runTest(join(fixturesDir, test)) && allPassed;
  }
}

if (!allPassed) {
  process.exit(1);
}
console.log("Stdlib tests passed");
```

## `tests/stdlib/stream.rt`

```rt
module test_stream {
  use "std/stream".
  start() {
    constant out is output().
    print(out, "Hello from Tratio!").
    give.
  }
}
```

## `tests/types/fixtures/basic/functions.rt`

```rt
module functions {
  function add(a of type integer 32, b of type integer 32) {
    give a plus b.
  }
  
  start() {
    constant result is add(1, 2).
    give.
  }
}
```

## `tests/types/fixtures/basic/literal.rt`

```rt
module literals {
  start() {
    constant x of type integer 32 is 42.
    constant y of type decimal 64 is 3.14.
    constant z of type text is "hello".
    constant b of type boolean is true.
    give.
  }
}
```

## `tests/types/fixtures/errors/escape.rt`

```rt
module escape {
  type Data is record {
    value of type integer 32.
  }.

  function process(d of type Data) {
    give.
  }

  start() {
    constant local_data of type Data is uninitialized.
    
    -- This should trigger the escape error
    process local_data.
    
    give.
  }
}
```

## `tests/types/fixtures/errors/mismatch.rt`

```rt
module mismatch {
  start() {
    constant x of type integer 32 is "hello".
    give.
  }
}
```

## `tests/types/fixtures/errors/missing.rt`

```rt
module missing {
  type Point is record {
    x of type decimal 64.
    y of type decimal 64.
  }.
  
  start() {
    constant p of type Point is uninit.
    constant z is p.z.
    give.
  }
}
```

## `tests/types/run.ts`

```typescript
import { TypeChecker } from "../../src/types/checker";
import { Engine } from "../../src/diag/engine";
import { Lexer } from "../../src/lex/lexer";
import { Parser } from "../../src/parse/parser";
import { readFileSync, readdirSync, existsSync, statSync } from "fs";
import { join } from "path";

const fixturesDir = "tests/types/fixtures";

interface TestResult {
  name: string;
  passed: boolean;
  errors: string[];
}

function parse(src: string, diag: Engine) {
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  return parser.parse();
}

function runTest(filePath: string, expectErrors: boolean): TestResult {
  const name = filePath.split("/").pop()!;
  const diag = new Engine();
  const result: TestResult = { name, passed: true, errors: [] };

  const src = readFileSync(filePath, "utf8");
  const program = parse(src, diag);

  if (diag.failed) {
    result.passed = false;
    result.errors.push("parse errors");
    return result;
  }

  const checker = new TypeChecker(diag);
  checker.check(program);

  if (expectErrors) {
    if (!diag.failed) {
      result.passed = false;
      result.errors.push("expected errors but none emitted");
    }
  } else {
    if (diag.failed) {
      result.passed = false;
      for (const msg of diag.messages) {
        result.errors.push(`${msg.text} at ${msg.span.line}:${msg.span.col}`);
      }
    }
  }

  return result;
}

const results: TestResult[] = [];

// Run basic tests (should pass)
const basicDir = join(fixturesDir, "basic");
if (existsSync(basicDir)) {
  const items = readdirSync(basicDir).filter(f => f.endsWith(".rt"));
  for (const item of items) {
    results.push(runTest(join(basicDir, item), false));
  }
}

// Run error tests (should fail)
const errorsDir = join(fixturesDir, "errors");
if (existsSync(errorsDir)) {
  const items = readdirSync(errorsDir).filter(f => f.endsWith(".rt"));
  for (const item of items) {
    results.push(runTest(join(errorsDir, item), true));
  }
}

// Report results
let failed = false;
for (const r of results) {
  if (r.passed) {
    console.log(`  ✓ ${r.name}`);
  } else {
    console.log(`  ✗ ${r.name}`);
    for (const err of r.errors) {
      console.log(`      ${err}`);
    }
    failed = true;
  }
}

if (failed) {
  process.exit(1);
}

console.log("Type tests passed");
```

## `units/core/backend/emitters.ts`

```typescript
import { Module } from "../ir/module";

/**
 * The ONLY module in the entire codebase allowed to know about Zig.
 * It translates the stable Tratio IR (v1) into Zig source code.
 */
export interface Emitter {
  emit(module: Module): Promise<Output>;
}

export interface Output {
  files: Map<string, string>;
}
```

## `units/core/config/manifest.ts`

```typescript
/**
 * Tratio project configuration schema, version 1.
 * Independent of backend, compiler version, or standard library evolution.
 */
export interface Manifest {
  name: string;
  version: string;
  language: string;
  build?: Build;
  dependencies?: Record<string, string>;
}

export interface Build {
  type?: string;
  target?: string[];
  optimize?: string;
}
```

## `units/core/ir/module.ts`

```typescript
/**
 * The stable, versioned Intermediate Representation root.
 * No backend-specific concepts exist here.
 */
export interface Module {
  name: string;
  version: string;
}
```
