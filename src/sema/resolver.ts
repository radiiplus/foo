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