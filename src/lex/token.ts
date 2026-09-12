import { Kind } from "./kind";
import { Span } from "../diag/span";

export interface Token {
  kind: Kind;
  span: Span;
  text: string;
}