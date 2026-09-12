import { Scope } from "./scope";
import * as ast from "../ast/node";

export interface Module {
  name: string;
  scope: Scope;
  node: ast.Module;
}

export interface Resolution {
  modules: Map<string, Module>;
  resolutions: Map<ast.Node, Symbol>;
}