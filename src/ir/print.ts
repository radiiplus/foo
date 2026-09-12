import * as ir from "./node";
import { TypeKind, ValueKind, InstrKind } from "./kind";

function typeStr(t: ir.Type): string {
  switch (t.kind) {
    case TypeKind.Int: return t.width ? `int${t.width}` : "int";
    case TypeKind.Float: return t.width ? `float${t.width}` : "float";
    case TypeKind.Bool: return "bool";
    case TypeKind.Ptr: return `ptr<${typeStr(t.elem!)}>`;
    case TypeKind.Array: return `[${t.width}]${typeStr(t.elem!)}`;
    case TypeKind.Struct: return t.name || "struct";
    case TypeKind.Void: return "void";
    case TypeKind.Error: return "error";
  }
}

function valueStr(v: ir.Value): string {
  switch (v.kind) {
    case ValueKind.Reg: return `%${v.name}`;
    case ValueKind.Const: return v.name;
    case ValueKind.Global: return `@${v.name}`;
  }
}

export function print(m: ir.Module): string {
  let out = `module ${m.name} {\n\n`;
  for (const ext of m.externs) {
    const params = ext.params.map(typeStr).join(", ");
    out += `  extern "${ext.abi}" fn @${ext.name}(${params}) -> ${typeStr(ext.ret)}\n`;
  }
  if (m.externs.length > 0) out += "\n";
  for (const f of m.funcs) {
    const params = f.params.map(p => `${valueStr(p)}: ${typeStr(p.type)}`).join(", ");
    const tparams = f.typeParams ? `[${f.typeParams.join(", ")}]` : "";
    out += `fn @${f.name}${tparams}(${params}) -> ${typeStr(f.ret)} {\n`;
    for (const b of f.blocks) {
      out += `\n${b.label}:\n`;
      for (const i of b.instrs) {
        out += `  ${printInstr(i)}\n`;
      }
      out += `  ${printInstr(b.term)}\n`;
    }
    out += "}\n\n";
  }
  return out.trim() + "\n}";
}

function printInstr(i: ir.Instruction): string {
  const dest = i.dest ? `${valueStr(i.dest)} = ` : "";
  switch (i.kind) {
    case InstrKind.Alloc:
      return `${dest}alloc ${i.region} ${typeStr(i.dest!.type)}`;
    case InstrKind.Load:
      return `${dest}load ${valueStr(i.ptr!)}`;
    case InstrKind.Store:
      return `store ${valueStr(i.val!)}, ${valueStr(i.ptr!)}`;
    case InstrKind.Add:
      return `${dest}add ${valueStr(i.val!)}, ${valueStr(i.val2!)}`;
    case InstrKind.Sub:
      return `${dest}sub ${valueStr(i.val!)}, ${valueStr(i.val2!)}`;
    case InstrKind.Mul:
      return `${dest}mul ${valueStr(i.val!)}, ${valueStr(i.val2!)}`;
    case InstrKind.Div:
      return `${dest}div ${valueStr(i.val!)}, ${valueStr(i.val2!)}`;
    case InstrKind.Call: {
      const args = (i.args || []).map(valueStr).join(", ");
      const targs = i.typeArgs ? `[${i.typeArgs.map(typeStr).join(", ")}]` : "";
      return `${dest}call @${i.func}${targs}(${args})`;
    }
    case InstrKind.Jump:
      return `jump ${i.label}`;
    case InstrKind.Cjump:
      return `cjump ${valueStr(i.cond!)}, ${i.trueLabel}, ${i.falseLabel}`;
    case InstrKind.Return:
      return i.value ? `return ${valueStr(i.value)}` : "return";
    case InstrKind.Panic:
      return `panic "${i.msg}"`;
    case InstrKind.Try:
      return `${dest}try ${valueStr(i.expr!)}, ${i.handler}`;
    case InstrKind.Phi:
      const sources = (i.blocks || []).map(b => `[${b.label}: ${valueStr(b.value)}]`).join(", ");
      return `${dest}phi ${sources}`;
    case InstrKind.Eval:
      return `${dest}eval "${i.evalBody}"`;
    case InstrKind.Reflect:
      return `${dest}reflect ${typeStr(i.typeArg!)}`;
    case InstrKind.Embed:
      return `${dest}embed "${i.path}"`;
  }
}