import * as ast from "../ast/node";
import { Engine } from "../diag/engine";
import { Code } from "../diag/code";
import { Type, ChoiceType } from "./type";

export function checkExhaustiveness(
  scrutineeType: Type,
  cases: ast.Case[],
  span: any,
  diag: Engine
): void {
  if (scrutineeType.kind !== "choice") {
    // For non-choice types, just check for wildcard
    const hasWildcard = cases.some(c => c.pattern.tag === "wildcard");
    if (!hasWildcard && cases.length === 0) {
      diag.emit(Code.Invalid, span, `match must have at least one case`);
    }
    return;
  }

  const choiceType = scrutineeType as ChoiceType;
  const coveredVariants = new Set<string>();
  let hasWildcard = false;

  for (const c of cases) {
    if (c.pattern.tag === "wildcard") {
      hasWildcard = true;
    } else if (c.pattern.tag === "name") {
      if (choiceType.variants.has(c.pattern.text)) {
        coveredVariants.add(c.pattern.text);
      }
    }
  }

  if (!hasWildcard) {
    const missing: string[] = [];
    for (const variant of choiceType.variants.keys()) {
      if (!coveredVariants.has(variant)) {
        missing.push(variant);
      }
    }

    if (missing.length > 0) {
      diag.emit(Code.Invalid, span, 
        `match is not exhaustive: missing cases for ${missing.join(", ")}`);
    }
  }
}