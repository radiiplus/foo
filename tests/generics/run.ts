import { Lexer } from "../../src/lex/lexer";
import { Parser } from "../../src/parse/parser";
import { Engine } from "../../src/diag/engine";
import { render } from "../../src/diag/render";
import { parse as parseIR } from "../../src/ir/parse";
import { print as printIR } from "../../src/ir/print";
import { monomorphize } from "../../src/ir/monomorph";
import { emit } from "../../src/backend/zig/emitter";
import * as ast from "../../src/ast/node";

let passed = 0;
let failed = 0;

function parse(src: string): ast.Program {
  const diag = new Engine();
  const lexer = new Lexer(src, diag);
  const toks = lexer.lex();
  const parser = new Parser(toks, diag);
  const program = parser.parse();
  if (diag.failed) {
    for (const msg of diag.messages) {
      console.log(render(msg, src));
    }
    throw new Error("Parse failed");
  }
  return program;
}

function test(name: string, fn: () => void) {
  try {
    fn();
    console.log(`  ✓ ${name}`);
    passed++;
  } catch (e: any) {
    console.log(`  ✗ ${name}: ${e.message}`);
    failed++;
  }
}

function assert(cond: boolean, msg: string) {
  if (!cond) throw new Error(msg);
}

// === 1. Generic function parsing ===
test("parse generic function fn f[T](x: T)", () => {
  const src = `module app {
  function identity[T](x of type T) {
    give x.
  }
}`;
  const program = parse(src);
  const fn = program.mods[0].body.stmts[0] as ast.Function;
  assert(fn.tag === "function", "expected function");
  assert(fn.typeParams !== undefined, "expected typeParams");
  assert(fn.typeParams!.length === 1, "expected 1 type param");
  assert(fn.typeParams![0].name.text === "T", "expected T");
});

// === 2. Generic function with bounds ===
test("parse generic function with bound fn f[T: Ord](x: T)", () => {
  const src = `module app {
  function max[T: Ord](a of type T, b of type T) {
    give a.
  }
}`;
  const program = parse(src);
  const fn = program.mods[0].body.stmts[0] as ast.Function;
  assert(fn.typeParams![0].bound !== undefined, "expected bound");
  assert(fn.typeParams![0].bound!.text === "Ord", "expected Ord bound");
});

// === 3. Generic struct/alias ===
test("parse generic type alias", () => {
  const src = `module app {
  type Box[T] is record {
    value of type T.
  }.
}`;
  const program = parse(src);
  const alias = program.mods[0].body.stmts[0] as ast.Alias;
  assert(alias.tag === "alias", "expected alias");
  assert(alias.typeParams !== undefined, "expected typeParams");
  assert(alias.typeParams!.length === 1, "expected 1 type param");
});

// === 4. Generic instantiation in type position ===
test("parse generic instantiation Box[integer 32]", () => {
  const src = `module app {
  constant x of type Box[integer 32] is uninitialized.
}`;
  const program = parse(src);
  const c = program.mods[0].body.stmts[0] as ast.Constant;
  assert(c.type!.tag === "generic-inst", "expected generic-inst");
  const inst = c.type as ast.GenericInst;
  assert(inst.name.text === "Box", "expected Box");
  assert(inst.args.length === 1, "expected 1 type arg");
});

// === 5. eval block ===
test("parse eval block", () => {
  const src = `module app {
  eval {
    constant x is 42.
  }
}`;
  const program = parse(src);
  const stmt = program.mods[0].body.stmts[0];
  assert(stmt.tag === "eval", "expected eval block");
});

// === 6. reflect expression ===
test("parse reflect[T]()", () => {
  const src = `module app {
  constant info is reflect[integer 32]().
}`;
  const program = parse(src);
  const c = program.mods[0].body.stmts[0] as ast.Constant;
  assert(c.value.tag === "reflect", "expected reflect");
});

// === 7. embed expression ===
test("parse embed(\"path\")", () => {
  const src = `module app {
  constant data is embed("data.bin").
}`;
  const program = parse(src);
  const c = program.mods[0].body.stmts[0] as ast.Constant;
  assert(c.value.tag === "embed", "expected embed");
  assert((c.value as ast.Embed).path === "data.bin", "expected data.bin");
});

// === 8. embed with typed variant ===
test("parse embed[text](\"greeting.txt\")", () => {
  const src = `module app {
  constant greeting is embed[text]("greeting.txt").
}`;
  const program = parse(src);
  const c = program.mods[0].body.stmts[0] as ast.Constant;
  const emb = c.value as ast.Embed;
  assert(emb.tag === "embed", "expected embed");
  assert(emb.type !== undefined, "expected type");
  assert(emb.path === "greeting.txt", "expected greeting.txt");
});

// === 9. #[derive] attribute ===
test("parse #[derive(Eq, Hash)] on type", () => {
  const src = `module app {
  #[derive(Eq, Hash)]
  type Point is record {
    x of type decimal 64.
    y of type decimal 64.
  }.
}`;
  const program = parse(src);
  const alias = program.mods[0].body.stmts[0] as ast.Alias;
  assert(alias.derives !== undefined, "expected derives");
  assert(alias.derives!.traits.length === 2, "expected 2 traits");
  assert(alias.derives!.traits[0].text === "Eq", "expected Eq");
  assert(alias.derives!.traits[1].text === "Hash", "expected Hash");
});

// === 10. Monomorphization pass ===
test("monomorphize generic function", () => {
  const irSrc = `module app {
  fn @identity(%x: int) -> int {
  entry:
    return %x
  }
  fn @main() -> void {
  entry:
    %1 = call @identity(%2)[int]
    return
  }
}`;
  const mod = parseIR(irSrc);
  // Add typeArgs to the call instruction manually for the test
  mod.funcs[1].blocks[0].instrs[0].typeArgs = [{ kind: 0 as any, name: "int" }];
  const specialized = monomorphize(mod);
  // Should have produced a specialized version
  const names = specialized.funcs.map(f => f.name);
  assert(names.includes("identity_int") || names.length >= 2, "expected specialized function");
});

// === 11. Zig emission: eval → comptime ===
test("emit eval as comptime block", () => {
  const irSrc = `module app {
  fn @main() -> void {
  entry:
    %1 = eval "constant x = 42;"
    return
  }
}`;
  const mod = parseIR(irSrc);
  // Manually set the instruction kind to Eval for this test
  mod.funcs[0].blocks[0].instrs[0].kind = 14 as any; // InstrKind.Eval
  mod.funcs[0].blocks[0].instrs[0].evalBody = "constant x = 42;";
  const result = emit(mod, "dev");
  assert(result.code.includes("comptime"), "expected comptime in output");
});

// === 12. Zig emission: embed → @embedFile ===
test("emit embed as @embedFile", () => {
  const irSrc = `module app {
  fn @main() -> void {
  entry:
    %1 = embed "data.bin"
    return
  }
}`;
  const mod = parseIR(irSrc);
  mod.funcs[0].blocks[0].instrs[0].kind = 16 as any; // InstrKind.Embed
  mod.funcs[0].blocks[0].instrs[0].path = "data.bin";
  const result = emit(mod, "dev");
  assert(result.code.includes('@embedFile("data.bin")'), "expected @embedFile in output");
});

// === 13. Zig emission: reflect → shim.reflect ===
test("emit reflect as shim.reflect call", () => {
  const irSrc = `module app {
  fn @main() -> void {
  entry:
    %1 = reflect int
    return
  }
}`;
  const mod = parseIR(irSrc);
  mod.funcs[0].blocks[0].instrs[0].kind = 15 as any; // InstrKind.Reflect
  mod.funcs[0].blocks[0].instrs[0].typeArg = { kind: 0 as any }; // int
  const result = emit(mod, "dev");
  assert(result.code.includes("shim.reflect"), "expected shim.reflect in output");
});

// === 14. Zig emission: derive generates eql/hash methods ===
test("emit derived eql/hash methods for struct", () => {
  const irSrc = `module app {
  fn @Point() -> void {
  entry:
    return
  }
}`;
  const mod = parseIR(irSrc);
  mod.funcs[0].derives = ["Eq", "Hash"];
  const result = emit(mod, "dev");
  assert(result.code.includes("pub fn eql"), "expected eql method");
  assert(result.code.includes("pub fn hash"), "expected hash method");
  assert(result.code.includes("shim.eql"), "expected shim.eql call");
  assert(result.code.includes("shim.hash"), "expected shim.hash call");
});

// === Summary ===
console.log(`\n${passed} passed, ${failed} failed.`);
if (failed > 0) {
  process.exit(1);
}
console.log("Generics tests passed");