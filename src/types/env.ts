import { Type } from "./type";

export class TypeEnv {
  private parent?: TypeEnv;
  private types: Map<string, Type>;

  constructor(parent?: TypeEnv) {
    this.parent = parent;
    this.types = new Map();
  }

  define(name: string, type: Type): void {
    this.types.set(name, type);
  }

  lookup(name: string): Type | undefined {
    const local = this.types.get(name);
    if (local) return local;
    if (this.parent) return this.parent.lookup(name);
    return undefined;
  }

  child(): TypeEnv {
    return new TypeEnv(this);
  }
}