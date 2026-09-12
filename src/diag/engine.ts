import { Span } from "./span";
import { Code } from "./code";
import { Note } from "./note";

export interface Message {
  code: Code;
  span: Span;
  text: string;
  notes: Note[];
  suggestion?: string;
  context?: string;
  relatedSpans?: { span: Span; text: string }[];
  source?: string;
}

export class Engine {
  private list: Message[] = [];
  private source?: string;

  setSource(source: string): void {
    this.source = source;
  }

  emit(code: Code, span: Span, text: string, context?: string, source?: string): void {
    const msg: Message = { 
      code, 
      span, 
      text, 
      notes: [],
      context,
      source
    };
    this.list.push(msg);
  }

  note(span: Span, text: string, fix?: string): void {
    const msg = this.list[this.list.length - 1];
    if (msg) {
      msg.notes.push({ span, text, fix });
    }
  }

  suggestion(text: string): void {
    const msg = this.list[this.list.length - 1];
    if (msg) {
      msg.suggestion = text;
    }
  }

  related(span: Span, text: string): void {
    const msg = this.list[this.list.length - 1];
    if (msg) {
      if (!msg.relatedSpans) msg.relatedSpans = [];
      msg.relatedSpans.push({ span, text });
    }
  }

  get messages(): Message[] {
    return this.list;
  }

  get failed(): boolean {
    return this.list.length > 0;
  }

  getSource(): string | undefined {
    return this.source;
  }
}