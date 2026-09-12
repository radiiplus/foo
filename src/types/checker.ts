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