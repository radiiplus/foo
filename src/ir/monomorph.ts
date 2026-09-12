import * as ir from "./node";
import { InstrKind, TypeKind } from "./kind";

export function monomorphize(mod: ir.Module): ir.Module {
  const newFuncs: ir.Function[] = [];
  const genericFuncs = new Map<string, ir.Function>();
  
  for (const f of mod.funcs) {
    if (f.typeParams && f.typeParams.length > 0) {
      genericFuncs.set(f.name, f);
    } else {
      newFuncs.push(f);
    }
  }

  const queue: { funcName: string; typeArgs: ir.Type[] }[] = [];
  const specialized = new Map<string, string>();

  for (const f of mod.funcs) {
    for (const b of f.blocks) {
      for (const i of [...b.instrs, b.term]) {
        if (i.kind === InstrKind.Call && i.typeArgs && i.typeArgs.length > 0) {
          queue.push({ funcName: i.func!, typeArgs: i.typeArgs });
        }
      }
    }
  }

  while (queue.length > 0) {
    const { funcName, typeArgs } = queue.shift()!;
    const original = genericFuncs.get(funcName);
    if (!original) continue;

    const suffix = typeArgs.map(t => typeToString(t)).join("_");
    const newName = `${funcName}_${suffix}`;
    const key = `${funcName}_${suffix}`;

    if (specialized.has(key)) continue;
    specialized.set(key, newName);

    const clone = JSON.parse(JSON.stringify(original)) as ir.Function;
    clone.name = newName;
    clone.typeParams = undefined;
    
    const typeMap = new Map<string, ir.Type>();
    for (let i = 0; i < original.typeParams!.length; i++) {
      typeMap.set(original.typeParams![i], typeArgs[i]);
    }
    
    substituteTypes(clone, typeMap);
    newFuncs.push(clone);

    for (const b of clone.blocks) {
      for (const i of [...b.instrs, b.term]) {
        if (i.kind === InstrKind.Call && i.typeArgs && i.typeArgs.length > 0) {
          for (let j = 0; j < i.typeArgs.length; j++) {
            if (i.typeArgs[j].kind === TypeKind.Struct && typeMap.has(i.typeArgs[j].name!)) {
              i.typeArgs[j] = typeMap.get(i.typeArgs[j].name!)!;
            }
          }
          queue.push({ funcName: i.func!, typeArgs: i.typeArgs });
        }
      }
    }
  }

  for (const f of newFuncs) {
    for (const b of f.blocks) {
      for (const i of [...b.instrs, b.term]) {
        if (i.kind === InstrKind.Call && i.typeArgs && i.typeArgs.length > 0) {
          const suffix = i.typeArgs.map(t => typeToString(t)).join("_");
          const key = `${i.func}_${suffix}`;
          if (specialized.has(key)) {
            i.func = specialized.get(key);
            i.typeArgs = undefined;
          }
        }
      }
    }
  }

  return { ...mod, funcs: newFuncs };
}

function substituteTypes(func: ir.Function, typeMap: Map<string, ir.Type>) {
  for (const p of func.params) {
    p.type = substituteType(p.type, typeMap);
  }
  func.ret = substituteType(func.ret, typeMap);
  
  for (const b of func.blocks) {
    for (const i of [...b.instrs, b.term]) {
      if (i.dest) i.dest.type = substituteType(i.dest.type, typeMap);
      if (i.val) i.val.type = substituteType(i.val.type, typeMap);
      if (i.val2) i.val2.type = substituteType(i.val2.type, typeMap);
      if (i.ptr) i.ptr.type = substituteType(i.ptr.type, typeMap);
      if (i.cond) i.cond.type = substituteType(i.cond.type, typeMap);
      if (i.value) i.value.type = substituteType(i.value.type, typeMap);
      if (i.expr) i.expr.type = substituteType(i.expr.type, typeMap);
      if (i.args) for (const a of i.args) a.type = substituteType(a.type, typeMap);
    }
  }
}

function substituteType(t: ir.Type, typeMap: Map<string, ir.Type>): ir.Type {
  if (t.kind === TypeKind.Struct && typeMap.has(t.name!)) {
    return typeMap.get(t.name!)!;
  }
  if (t.elem) {
    return { ...t, elem: substituteType(t.elem, typeMap) };
  }
  return t;
}

function typeToString(t: ir.Type): string {
  switch (t.kind) {
    case TypeKind.Int: return t.width ? `i${t.width}` : "i32";
    case TypeKind.Float: return t.width ? `f${t.width}` : "f64";
    case TypeKind.Bool: return "bool";
    case TypeKind.Ptr: return `ptr_${typeToString(t.elem!)}`;
    case TypeKind.Array: return `arr_${typeToString(t.elem!)}`;
    case TypeKind.Struct: return t.name || "struct";
    case TypeKind.Void: return "void";
    case TypeKind.Error: return "error";
    default: return "unknown";
  }
}