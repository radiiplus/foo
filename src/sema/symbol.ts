import { Form } from "./form";
import * as ast from "../ast/node";

export interface Symbol {
  name: string;
  form: Form;
  visible: boolean;
  node: ast.Node;
  module?: string;
}