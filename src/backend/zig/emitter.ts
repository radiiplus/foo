import * as ir from "../../ir/node";
import { TypeKind, ValueKind, InstrKind } from "../../ir/kind";

export interface EmitResult {
  code: string;
  map: Map<number, number>;
}

function typeStr(t: ir.Type): string {
  switch (t.kind) {
    case TypeKind.Int: return t.width ? `i${t.width}` : "i32";
    case TypeKind.Float: return t.width ? `f${t.width}` : "f64";
    case TypeKind.Bool: return "bool";
    case TypeKind.Ptr: return `*${typeStr(t.elem!)}`;
    case TypeKind.Array: return `[${t.width}]${typeStr(t.elem!)}`;
    case TypeKind.Struct: return t.name || "struct";
    case TypeKind.Void: return "void";
    case TypeKind.Error: return "shim.Error";
  }
}

function valueStr(v: ir.Value): string {
  switch (v.kind) {
    case ValueKind.Reg: return `v_${v.name}`;
    case ValueKind.Const: return v.name;
    case ValueKind.Global: return `&${v.name}`;
  }
}

function usedRegisters(f: ir.Function): Set<string> {
  const used = new Set<string>();
  function add(value: ir.Value | undefined): void {
    if (value?.kind === ValueKind.Reg) used.add(value.name);
  }
  for (const block of f.blocks) {
    for (const instr of [...block.instrs, block.term]) {
      add(instr.target);
      add(instr.ptr);
      add(instr.val);
      add(instr.val2);
      add(instr.cond);
      add(instr.value);
      add(instr.expr);
      for (const arg of instr.args || []) add(arg);
      for (const source of instr.blocks || []) add(source.value);
    }
  }
  return used;
}

export function emit(mod: ir.Module, mode: string): EmitResult {
  let code = `// Tratio IR v1 -> Zig\n`;
  code += `const shim = @import("shim.zig");\n\n`;
  const map = new Map<number, number>();
  let zigLine = 3;
  
  function addLine(arcLine: number, text: string): void {
    map.set(arcLine, zigLine);
    code += text + "\n";
    zigLine++;
  }

  for (const ext of mod.externs) {
    const params = ext.params.map(typeStr).join(", ");
    addLine(0, `extern "c" fn ${ext.name}(${params}) ${typeStr(ext.ret)};`);
  }
  if (mod.externs.length > 0) addLine(0, "");
  
  for (const f of mod.funcs) {
    const used = usedRegisters(f);
    const params = f.params.map(p => `${valueStr(p)}: ${typeStr(p.type)}`).join(", ");
    addLine(0, `pub fn ${f.name}(${params}) ${typeStr(f.ret)} {`);
    if (f.name === "main") {
      addLine(0, `  shim.init(${mode === "dev"});`);
      addLine(0, "  defer shim.deinit();");
    }
    for (const b of f.blocks) {
      addLine(0, `  // block ${b.label}`);
      for (const i of b.instrs) {
        addLine(0, `  ${emitInstr(i, used)}`);
      }
      addLine(0, `  ${emitInstr(b.term, used)}`);
    }
    addLine(0, `}`);
    
    if (f.derives) {
      if (f.derives.includes("Eq")) {
        addLine(0, `pub fn eql(self: ${f.name}, other: ${f.name}) bool {`);
        addLine(0, `  return shim.eql(self, other);`);
        addLine(0, `}`);
      }
      if (f.derives.includes("Hash")) {
        addLine(0, `pub fn hash(self: ${f.name}) u64 {`);
        addLine(0, `  return shim.hash(self);`);
        addLine(0, `}`);
      }
    }
    addLine(0, "");
  }
  return { code, map };
}

function emitInstr(i: ir.Instruction, used: Set<string>): string {
  const dest = i.dest ? `const ${valueStr(i.dest)} = ` : "";
  const discard = i.dest && !used.has(i.dest.name) ? ` _ = ${valueStr(i.dest)};` : "";
  const finish = (text: string): string => text + discard;
  
  switch (i.kind) {
    case InstrKind.Alloc:
      return finish(`${dest}shim.allocScope(${typeStr(i.dest!.type)}) catch shim.panic("out of memory");`);
    case InstrKind.Load:
      return finish(`${dest}${valueStr(i.ptr!)}.*;`);
    case InstrKind.Store:
      return `${valueStr(i.ptr!)}.* = ${valueStr(i.val!)};`;
    case InstrKind.Add:
      return finish(`${dest}${valueStr(i.val!)} + ${valueStr(i.val2!)};`);
    case InstrKind.Sub:
      return finish(`${dest}${valueStr(i.val!)} - ${valueStr(i.val2!)};`);
    case InstrKind.Mul:
      return finish(`${dest}${valueStr(i.val!)} * ${valueStr(i.val2!)};`);
    case InstrKind.Div:
      return finish(`${dest}${valueStr(i.val!)} / ${valueStr(i.val2!)};`);
    case InstrKind.Call:
      return finish(`${dest}${i.func}(${(i.args || []).map(valueStr).join(", ")});`);
    case InstrKind.Jump:
      return `// jump ${i.label}`;
    case InstrKind.Cjump:
      return `if (${valueStr(i.cond!)}) { /* ${i.trueLabel} */ } else { /* ${i.falseLabel} */ }`;
    case InstrKind.Return:
      return i.value ? `return ${valueStr(i.value)};` : "return;";
    case InstrKind.Panic:
      return `shim.panic("${i.msg}");`;
    case InstrKind.Try:
      return finish(`${dest}try ${valueStr(i.expr!)};`);
    case InstrKind.Phi:
      return `// phi ${(i.blocks || []).map(b => `[${b.label}: ${valueStr(b.value)}]`).join(", ")}`;
    case InstrKind.Eval:
      return `comptime { ${i.evalBody || ""} }`;
    case InstrKind.Reflect:
      return finish(`${dest}shim.reflect(${typeStr(i.typeArg!)});`);
    case InstrKind.Embed:
      return finish(`${dest}@embedFile("${i.path}");`);
  }
}