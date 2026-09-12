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