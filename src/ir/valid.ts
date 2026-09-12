import * as ir from "./node";
import { ValueKind, InstrKind } from "./kind";

export interface ValidationError {
  msg: string;
}

export function validate(m: ir.Module): ValidationError[] {
  const errors: ValidationError[] = [];
  for (const f of m.funcs) {
    const defined = new Set<string>();
    const used = new Map<string, { line: number; col: number }>();
    for (const p of f.params) {
      defined.add(p.name);
    }
    for (const b of f.blocks) {
      for (const i of [...b.instrs, b.term]) {
        if (i.val && i.val.kind === ValueKind.Reg && !defined.has(i.val.name)) {
          errors.push({ msg: `Use of undefined register %${i.val.name}` });
        }
        if (i.val2 && i.val2.kind === ValueKind.Reg && !defined.has(i.val2.name)) {
          errors.push({ msg: `Use of undefined register %${i.val2.name}` });
        }
        if (i.cond && i.cond.kind === ValueKind.Reg && !defined.has(i.cond.name)) {
          errors.push({ msg: `Use of undefined register %${i.cond.name}` });
        }
        if (i.dest && i.dest.kind === ValueKind.Reg) {
          if (defined.has(i.dest.name)) {
            errors.push({ msg: `Redefinition of register %${i.dest.name}` });
          }
          defined.add(i.dest.name);
        }
        if (i.kind === InstrKind.Return || i.kind === InstrKind.Jump || i.kind === InstrKind.Cjump || i.kind === InstrKind.Panic) {
          if (i !== b.term) {
            errors.push({ msg: `Instruction ${i.kind} must be a terminator` });
          }
        }
      }
      if (b.term.kind !== InstrKind.Return && b.term.kind !== InstrKind.Jump && b.term.kind !== InstrKind.Cjump && b.term.kind !== InstrKind.Panic) {
        errors.push({ msg: `Block ${b.label} lacks a valid terminator` });
      }
    }
  }
  return errors;
}