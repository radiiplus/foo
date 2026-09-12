import * as ir from "./node";
import { TypeKind, ValueKind, InstrKind } from "./kind";

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
      if (this.pos < this.src.length) this.pos++;
      return { kind: "STRING", value };
    }
    if ("=,<>()[]{}:-<>".includes(ch)) {
      if (ch === "-" && this.src[this.pos + 1] === ">") {
        this.pos += 2;
        return { kind: "SYMBOL", value: "->" };
      }
      this.pos++;
      return { kind: "SYMBOL", value: ch };
    }
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
    const name = this.consume("IDENT").value.slice(1);
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
    const name = this.consume("IDENT").value.slice(1);
    
    let typeParams: string[] | undefined;
    if (this.match("SYMBOL", "[")) {
      typeParams = [];
      while (!this.match("SYMBOL", "]")) {
        typeParams.push(this.consume("IDENT").value);
        if (this.match("SYMBOL", ",")) this.consume("SYMBOL", ",");
      }
      this.consume("SYMBOL", "]");
    }

    this.consume("SYMBOL", "(");
    const params: ir.Value[] = [];
    while (!this.match("SYMBOL", ")")) {
      const pname = this.consume("IDENT").value.slice(1);
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
    return { name, typeParams, params, ret, blocks };
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
      dest = { kind: ValueKind.Reg, name, type: { kind: TypeKind.Void } };
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
        const func = this.consume("IDENT").value.slice(1);
        this.consume("SYMBOL", "(");
        const args: ir.Value[] = [];
        while (!this.match("SYMBOL", ")")) {
          args.push(this.parseValue());
          if (this.match("SYMBOL", ",")) {
            this.consume("SYMBOL", ",");
          }
        }
        this.consume("SYMBOL", ")");
        
        let typeArgs: ir.Type[] | undefined;
        if (this.match("SYMBOL", "[")) {
          this.consume("SYMBOL", "[");
          typeArgs = [];
          while (!this.match("SYMBOL", "]")) {
            typeArgs.push(this.parseType());
            if (this.match("SYMBOL", ",")) this.consume("SYMBOL", ",");
          }
          this.consume("SYMBOL", "]");
        }
        
        return { kind: InstrKind.Call, dest, func, args, typeArgs };
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
      case "eval": {
        const body = this.consume("STRING").value;
        return { kind: InstrKind.Eval, dest, evalBody: body };
      }
      case "reflect": {
        const typeArg = this.parseType();
        return { kind: InstrKind.Reflect, dest, typeArg };
      }
      case "embed": {
        const path = this.consume("STRING").value;
        return { kind: InstrKind.Embed, dest, path };
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
      return { kind: ValueKind.Const, name: `"${tok.value}"`, type: { kind: TypeKind.Int } };
    }
    throw new Error(`Expected value, got '${tok.value}'`);
  }
}

export function parse(src: string): ir.Module {
  const parser = new Parser(src);
  return parser.parse();
}
