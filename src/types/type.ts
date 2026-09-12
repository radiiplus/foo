export type Type =
  | PrimitiveType
  | ArrayType
  | SequenceType
  | OptionalType
  | ErrorType
  | PointerType
  | NamedType
  | RecordType
  | ChoiceType
  | FunctionType
  | LiteralType
  | UnknownType;

export interface PrimitiveType {
  kind: "primitive";
  name: string;
  width?: number;
}

export interface ArrayType {
  kind: "array";
  elem: Type;
}

export interface SequenceType {
  kind: "sequence";
  elem: Type;
}

export interface OptionalType {
  kind: "optional";
  elem: Type;
}

export interface ErrorType {
  kind: "error";
  elem: Type;
}

export interface PointerType {
  kind: "pointer";
  elem: Type;
}

export interface NamedType {
  kind: "named";
  name: string;
}

export interface RecordType {
  kind: "record";
  name: string;
  fields: Map<string, Type>;
}

export interface ChoiceType {
  kind: "choice";
  name: string;
  variants: Map<string, Type | undefined>;
}

export interface FunctionType {
  kind: "function";
  params: Type[];
  ret: Type;
}

export interface LiteralType {
  kind: "literal";
  value: string;
}

export interface UnknownType {
  kind: "unknown";
}

export function typeToString(t: Type): string {
  switch (t.kind) {
    case "primitive":
      return t.width ? `${t.name} ${t.width}` : t.name;
    case "array":
      return `array of ${typeToString(t.elem)}`;
    case "sequence":
      return `sequence of ${typeToString(t.elem)}`;
    case "optional":
      return `optional ${typeToString(t.elem)}`;
    case "error":
      return `error ${typeToString(t.elem)}`;
    case "pointer":
      return `pointer to ${typeToString(t.elem)}`;
    case "named":
      return t.name;
    case "record":
      return t.name;
    case "choice":
      return t.name;
    case "function":
      const params = t.params.map(typeToString).join(", ");
      return `function(${params}) -> ${typeToString(t.ret)}`;
    case "literal":
      return `literal ${t.value}`;
    case "unknown":
      return "unknown";
  }
}

export function typesEqual(a: Type, b: Type): boolean {
  if (a.kind !== b.kind) return false;
  
  switch (a.kind) {
    case "primitive":
      return a.name === (b as PrimitiveType).name && a.width === (b as PrimitiveType).width;
    case "array":
      return typesEqual(a.elem, (b as ArrayType).elem);
    case "sequence":
      return typesEqual(a.elem, (b as SequenceType).elem);
    case "optional":
      return typesEqual(a.elem, (b as OptionalType).elem);
    case "error":
      return typesEqual(a.elem, (b as ErrorType).elem);
    case "pointer":
      return typesEqual(a.elem, (b as PointerType).elem);
    case "named":
      return a.name === (b as NamedType).name;
    case "record":
    case "choice":
      return a.name === (b as RecordType | ChoiceType).name;
    case "function":
      const bf = b as FunctionType;
      if (a.params.length !== bf.params.length) return false;
      for (let i = 0; i < a.params.length; i++) {
        if (!typesEqual(a.params[i], bf.params[i])) return false;
      }
      return typesEqual(a.ret, bf.ret);
    case "literal":
      return a.value === (b as LiteralType).value;
    case "unknown":
      return true;
  }
}