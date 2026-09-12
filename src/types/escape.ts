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