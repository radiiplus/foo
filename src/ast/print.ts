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