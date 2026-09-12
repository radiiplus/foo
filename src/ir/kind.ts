export enum TypeKind {
  Int,
  Float,
  Bool,
  Ptr,
  Array,
  Struct,
  Void,
  Error
}

export enum ValueKind {
  Reg,
  Const,
  Global
}

export enum InstrKind {
  Alloc,
  Load,
  Store,
  Add,
  Sub,
  Mul,
  Div,
  Call,
  Jump,
  Cjump,
  Return,
  Panic,
  Try,
  Phi,
  Eval,
  Reflect,
  Embed
}