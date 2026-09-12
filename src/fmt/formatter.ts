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