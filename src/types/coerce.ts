import { Type, typesEqual, PrimitiveType, OptionalType, ErrorType } from "./type";

export interface CoercionResult {
  ok: boolean;
  type?: Type;
  reason?: string;
}

export function canCoerce(from: Type, to: Type): CoercionResult {
  // Exact match
  if (typesEqual(from, to)) {
    return { ok: true, type: to };
  }

  // Literal to primitive
  if (from.kind === "literal" && to.kind === "primitive") {
    return { ok: true, type: to };
  }

  // T → ?T (wrap in optional)
  if (to.kind === "optional") {
    const inner = canCoerce(from, to.elem);
    if (inner.ok) {
      return { ok: true, type: to };
    }
  }

  // ?T → ?U if T → U
  if (from.kind === "optional" && to.kind === "optional") {
    const inner = canCoerce(from.elem, to.elem);
    if (inner.ok) {
      return { ok: true, type: to };
    }
  }

  // !T → !U if T → U (error propagation)
  if (from.kind === "error" && to.kind === "error") {
    const inner = canCoerce(from.elem, to.elem);
    if (inner.ok) {
      return { ok: true, type: to };
    }
  }

  // No silent crossing between ?T and !T
  if ((from.kind === "optional" && to.kind === "error") ||
      (from.kind === "error" && to.kind === "optional")) {
    return { ok: false, reason: "cannot silently convert between optional and error types" };
  }

  // Numeric widening (e.g., integer 32 → integer 64)
  if (from.kind === "primitive" && to.kind === "primitive") {
    if (from.name === to.name && from.width && to.width) {
      if (from.width < to.width) {
        return { ok: true, type: to };
      }
    }
  }

  return { ok: false, reason: `cannot coerce to target type` };
}