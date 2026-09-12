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

  private attributes(): { derives?: ast.Derive } {
    let derives: ast.Derive | undefined;
    while (this.check(Kind.HashBracket)) {
      this.advance();
      if (this.check(Kind.Ident) && this.peek().text === "derive") {
        this.advance();
        this.expect(Kind.Paren, "expected '('");
        const traits: ast.Name[] = [];
        while (!this.check(Kind.Close) && !this.done()) {
          traits.push(this.name());
          if (!this.check(Kind.Close)) this.expect(Kind.Comma, "expected ','");
        }
        this.expect(Kind.Close, "expected ')'");
        derives = { span: this.span(), tag: "derive", traits };
      }
      this.expect(Kind.Bracket, "expected ']'");
    }
    return { derives };
  }

  private typeParams(): ast.TypeParam[] | undefined {
    if (!this.check(Kind.Square)) return undefined;
    this.advance();
    const params: ast.TypeParam[] = [];
    while (!this.check(Kind.Bracket) && !this.done()) {
      const name = this.name();
      let bound: ast.Name | undefined;
      if (this.match(Kind.Colon)) {
        bound = this.name();
      }
      params.push({ span: this.span(), tag: "type-param", name, bound });
      if (!this.check(Kind.Bracket)) this.expect(Kind.Comma, "expected ','");
    }
    this.expect(Kind.Bracket, "expected ']'");
    return params;
  }

  private stmt(): ast.Statement {
    this.mark();
    const attrs = this.attributes();
    this.skipNewlines();
    const pub = this.match(Kind.Public);
    
    if (this.check(Kind.Constant)) return this.constant(pub);
    if (this.check(Kind.Mutable)) return this.mutable(pub);
    if (this.check(Kind.Use)) return this.use(pub);
    if (this.check(Kind.Type)) {
      const alias = this.alias(pub);
      alias.derives = attrs.derives;
      return alias;
    }
    if (this.check(Kind.Function)) {
      const fn = this.function(pub);
      fn.derives = attrs.derives;
      return fn;
    }
    if (this.check(Kind.Start)) return this.entry(pub);
    if (this.check(Kind.Test)) return this.testBlock();
    if (this.check(Kind.Eval)) {
      this.advance();
      const body = this.block();
      return { span: this.span(), tag: "eval", body };
    }
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
    const typeParams = this.typeParams();
    this.expect(Kind.Paren, "expected '('");
    const params = this.params();
    this.expect(Kind.Close, "expected ')'");
    let constraint: ast.Constraint | undefined;
    if (this.match(Kind.Where)) {
      constraint = this.constraint();
    }
    const body = this.block();
    return { span: this.span(), tag: "function", public: pub, name, typeParams, params, constraint, body };
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
    const typeParams = this.typeParams();
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
    return { span: this.span(), tag: "alias", public: pub, name, typeParams, body };
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
    
    if (tok.kind === Kind.Reflect) {
      this.advance();
      this.expect(Kind.Square, "expected '['");
      const type = this.type();
      this.expect(Kind.Bracket, "expected ']'");
      this.expect(Kind.Paren, "expected '('");
      this.expect(Kind.Close, "expected ')'");
      return { span: this.span(), tag: "reflect", type };
    }
    
    if (tok.kind === Kind.Embed) {
      this.advance();
      let type: ast.Type | undefined;
      if (this.check(Kind.Square)) {
        this.advance();
        type = this.type();
        this.expect(Kind.Bracket, "expected ']'");
      }
      this.expect(Kind.Paren, "expected '('");
      const pathTok = this.expect(Kind.String, "expected path string");
      this.expect(Kind.Close, "expected ')'");
      return { span: this.span(), tag: "embed", path: pathTok.text, type };
    }

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
      if (this.check(Kind.Square)) {
        this.advance();
        const args: ast.Type[] = [];
        while (!this.check(Kind.Bracket) && !this.done()) {
          args.push(this.type());
          if (!this.check(Kind.Bracket)) this.expect(Kind.Comma, "expected ','");
        }
        this.expect(Kind.Bracket, "expected ']'");
        return { span: this.span(), tag: "generic-inst", name, args };
      }
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
