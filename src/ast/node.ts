import { Span } from "../diag/span";

export interface Node {
  span: Span;
  tag: string;
}

export interface Program extends Node { tag: "program"; mods: Module[]; }
export interface Module extends Node { tag: "module"; name: Name; body: Block; }

export type Declaration = Constant | Mutable | Function | Alias | Use;
export type Statement =
  | Constant | Mutable | Give | When | While | Repeat | For
  | Match | Break | Continue | Try | Defer | Unsafe | Action
  | Case | UnreachableStatement | AdvanceStatement | TestBlock | EvalBlock;

export type Expression =
  | Integer | Decimal | Text | Character
  | True | False | Uninitialized | Unreachable | Quantity | NewlineExpr
  | Name | Call | Unary | Binary | Group | Field | Index | ErrorChain
  | Reflect | Embed;

export type Type = Primitive | Array | Sequence | Optional | Error | Pointer | Named | GenericInst;
export type Pattern = Name | Wildcard | Integer | True | False;

export interface Integer extends Node { tag: "integer"; value: string; }
export interface Decimal extends Node { tag: "decimal"; value: string; }
export interface Text extends Node { tag: "text"; value: string; }
export interface Character extends Node { tag: "character"; value: string; }
export interface True extends Node { tag: "true"; }
export interface False extends Node { tag: "false"; }
export interface Uninitialized extends Node { tag: "uninitialized"; }
export interface Unreachable extends Node { tag: "unreachable"; }
export interface Quantity extends Node { tag: "quantity"; value: string; unit: string; }
export interface NewlineExpr extends Node { tag: "newline"; }
export interface Name extends Node { tag: "name"; text: string; }
export interface Call extends Node { tag: "call"; callee: Expression; args: Expression[]; }
export interface Unary extends Node { tag: "unary"; op: string; operand: Expression; }
export interface Binary extends Node { tag: "binary"; op: string; left: Expression; right: Expression; }
export interface Group extends Node { tag: "group"; expr: Expression; }
export interface Field extends Node { tag: "field"; object: Expression; field: Name; }
export interface Index extends Node { tag: "index"; object: Expression; index: Expression; }
export interface ErrorChain extends Node { tag: "error-chain"; expr: Expression; context: Expression; }

export interface TypeParam extends Node { tag: "type-param"; name: Name; bound?: Name; }
export interface GenericInst extends Node { tag: "generic-inst"; name: Name; args: Type[]; }
export interface EvalBlock extends Node { tag: "eval"; body: Block; }
export interface Reflect extends Node { tag: "reflect"; type: Type; }
export interface Embed extends Node { tag: "embed"; path: string; type?: Type; }
export interface Derive extends Node { tag: "derive"; traits: Name[]; }

export interface Constant extends Node { tag: "constant"; public: boolean; name: Name; type?: Type; value: Expression; }
export interface Mutable extends Node { tag: "mutable"; public: boolean; name: Name; type?: Type; value: Expression; }
export interface Function extends Node { 
  tag: "function"; 
  public: boolean; 
  name: Name; 
  typeParams?: TypeParam[]; 
  params: Parameter[]; 
  constraint?: Constraint; 
  body: Block; 
  derives?: Derive;
}
export interface Alias extends Node { 
  tag: "alias"; 
  public: boolean; 
  name: Name; 
  typeParams?: TypeParam[]; 
  body: Record | Choice | Type; 
  derives?: Derive;
}
export interface Use extends Node { 
  tag: "use"; 
  public: boolean; 
  name: Name;
  path?: string;
}
export interface Give extends Node { tag: "give"; value?: Expression; }
export interface When extends Node { tag: "when"; cond: Expression; then: Block; else?: Block | When; }
export interface While extends Node { tag: "while"; cond: Expression; body: Block; }
export interface Repeat extends Node { tag: "repeat"; target: Name; limit: Expression; body: Block; }
export interface For extends Node { tag: "for"; bind: Name; iter: Expression; body: Block; }
export interface Match extends Node { tag: "match"; scrutinee: Expression; cases: Case[]; }
export interface Break extends Node { tag: "break"; }
export interface Continue extends Node { tag: "continue"; }
export interface Try extends Node { tag: "try"; expr: Expression; }
export interface Defer extends Node { tag: "defer"; body: Expression | Block; }
export interface Unsafe extends Node { tag: "unsafe"; body: Block; }
export interface Action extends Node { tag: "action"; name: Name; args: Expression[]; }
export interface Case extends Node { tag: "case"; pattern: Pattern; body: Block; }
export interface UnreachableStatement extends Node { tag: "unreachable-statement"; }
export interface AdvanceStatement extends Node { tag: "advance"; target: Name; }
export interface TestBlock extends Node { tag: "test"; name: Text; body: Block; }

export interface Record extends Node { tag: "record"; fields: Member[]; }
export interface Member extends Node { tag: "member"; name: Name; type: Type; }
export interface Choice extends Node { tag: "choice"; variants: Variant[]; }
export interface Variant extends Node { tag: "variant"; name: Name; value?: Integer; }

export interface Primitive extends Node { tag: "primitive"; name: string; width?: string; }
export interface Array extends Node { tag: "array"; elem: Type; }
export interface Sequence extends Node { tag: "sequence"; elem: Type; }
export interface Optional extends Node { tag: "optional"; elem: Type; }
export interface Error extends Node { tag: "error"; elem: Type; }
export interface Pointer extends Node { tag: "pointer"; elem: Type; }
export interface Named extends Node { tag: "named"; name: Name; }

export interface Parameter extends Node { tag: "parameter"; name: Name; type: Type; }
export interface Constraint extends Node { tag: "constraint"; subject: Name; trait: Name; }
export interface Block extends Node { tag: "block"; stmts: Statement[]; }
export interface Wildcard extends Node { tag: "wildcard"; }
export interface Broken extends Node { tag: "broken"; }