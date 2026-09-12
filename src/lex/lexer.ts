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

    if (ch === "\n") {
      this.mark();
      this.read();
      return { kind: Kind.NewlineToken, span: this.span(), text: "\n" };
    }

    if (ch === "-" && this.src[this.pos + 1] === "-" && this.src[this.pos + 2] === "-") {
      this.multilineComment();
      return this.next();
    }

    if (ch === "-" && this.src[this.pos + 1] === "-") {
      this.scanline();
      return this.next();
    }

    if (ch === '"') {
      return this.string();
    }

    if (ch === "'") {
      return this.character();
    }

    if (this.digit(ch)) {
      return this.number();
    }

    if (this.letter(ch) || ch === "_") {
      return this.word();
    }

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
      eval: Kind.Eval, reflect: Kind.Reflect, embed: Kind.Embed,
    };
    return { kind: keywords[text] || Kind.Ident, span: this.span(), text };
  }

  private symbol(): Token {
    this.mark();
    const ch = this.read();
    let kind = Kind.Broken;
    
    if (ch === '#' && this.pos < this.src.length && this.src[this.pos] === '[') {
      this.read();
      return { kind: Kind.HashBracket, span: this.span(), text: "#[" };
    }
    
    switch (ch) {
      case "{": kind = Kind.Open; break;
      case "}": kind = Kind.Shut; break;
      case "(": kind = Kind.Paren; break;
      case ")": kind = Kind.Close; break;
      case "[": kind = Kind.Square; break;
      case "]": kind = Kind.Bracket; break;
      case ".": kind = Kind.Dot; break;
      case ",": kind = Kind.Comma; break;
      case ":": kind = Kind.Colon; break;
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