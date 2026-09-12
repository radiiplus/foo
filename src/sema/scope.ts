import { Symbol } from "./symbol";

export class Scope {
  private parent?: Scope;
  private symbols: Map<string, Symbol>;

  constructor(parent?: Scope) {
    this.parent = parent;
    this.symbols = new Map();
  }

  insert(name: string, symbol: Symbol): boolean {
    if (this.symbols.has(name)) {
      return false;
    }
    this.symbols.set(name, symbol);
    return true;
  }

  lookup(name: string): Symbol | undefined {
    const local = this.symbols.get(name);
    if (local) return local;
    if (this.parent) return this.parent.lookup(name);
    return undefined;
  }

  lookupLocal(name: string): Symbol | undefined {
    return this.symbols.get(name);
  }
}