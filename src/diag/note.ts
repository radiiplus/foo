import { Span } from "./span";

export interface Note {
  span: Span;
  text: string;
  fix?: string;
}