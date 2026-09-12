import { TypeKind, ValueKind, InstrKind } from "./kind";

export interface Type {
  kind: TypeKind;
  name?: string;
  elem?: Type;
  width?: number;
  fields?: Map<string, Type>;
}

export interface Value {
  kind: ValueKind;
  name: string;
  type: Type;
}

export interface Instruction {
  kind: InstrKind;
  dest?: Value;
  region?: string;
  target?: Value;
  ptr?: Value;
  val?: Value;
  val2?: Value;
  func?: string;
  args?: Value[];
  label?: string;
  cond?: Value;
  trueLabel?: string;
  falseLabel?: string;
  value?: Value;
  blocks?: { label: string; value: Value }[];
  msg?: string;
  expr?: Value;
  handler?: string;
  path?: string;
  typeArg?: Type;
  evalBody?: string;
  typeArgs?: Type[];
}

export interface Block {
  label: string;
  instrs: Instruction[];
  term: Instruction;
}

export interface Function {
  name: string;
  typeParams?: string[];
  params: Value[];
  ret: Type;
  blocks: Block[];
  derives?: string[];
}

export interface Extern {
  name: string;
  params: Type[];
  ret: Type;
  abi: string;
}

export interface Module {
  name: string;
  funcs: Function[];
  externs: Extern[];
}