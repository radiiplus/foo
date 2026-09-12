import { Message } from "./engine";
import { Code } from "./code";

// ANSI color codes
const colors = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  dim: "\x1b[2m",
  red: "\x1b[31m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
  magenta: "\x1b[35m",
  cyan: "\x1b[36m",
  white: "\x1b[37m",
  brightRed: "\x1b[91m",
  brightGreen: "\x1b[92m",
  brightYellow: "\x1b[93m",
  brightBlue: "\x1b[94m",
  brightMagenta: "\x1b[95m",
  brightCyan: "\x1b[96m",
  brightWhite: "\x1b[97m",
};

const codeMessages: Record<Code, { title: string; description: string }> = {
  [Code.Unexpected]: {
    title: "Unexpected token",
    description: "I found something I wasn't expecting here"
  },
  [Code.Unterminated]: {
    title: "Unterminated",
    description: "This never got closed properly"
  },
  [Code.Invalid]: {
    title: "Invalid",
    description: "This isn't valid"
  },
  [Code.InvalidEscape]: {
    title: "Invalid escape sequence",
    description: "This escape sequence isn't recognized"
  },
  [Code.Digit]: {
    title: "Invalid digit",
    description: "This digit doesn't belong here"
  },
  [Code.Syntax]: {
    title: "Syntax error",
    description: "The syntax here isn't quite right"
  },
  [Code.Missing]: {
    title: "Missing",
    description: "I can't find this"
  },
  [Code.Extra]: {
    title: "Extra",
    description: "There's something extra here that shouldn't be"
  },
  [Code.Duplicate]: {
    title: "Duplicate",
    description: "This is already defined"
  },
  [Code.Hidden]: {
    title: "Hidden",
    description: "This isn't accessible from here"
  },
  [Code.Clash]: {
    title: "Conflict",
    description: "This conflicts with something else"
  },
  [Code.Absent]: {
    title: "Not found",
    description: "I couldn't find this module"
  },
  [Code.Circular]: {
    title: "Circular dependency",
    description: "These modules depend on each other in a loop"
  },
  [Code.TypeMismatch]: {
    title: "Type mismatch",
    description: "The types don't match up"
  },
  [Code.NotCallable]: {
    title: "Not callable",
    description: "You can't call this like a function"
  },
  [Code.NotIndexable]: {
    title: "Not indexable",
    description: "You can't index into this"
  },
  [Code.NotIterable]: {
    title: "Not iterable",
    description: "You can't iterate over this"
  },
  [Code.FieldNotFound]: {
    title: "Field not found",
    description: "This record doesn't have that field"
  },
  [Code.VariantNotFound]: {
    title: "Variant not found",
    description: "This choice doesn't have that variant"
  },
  [Code.ScopeEscape]: {
    title: "Scope escape",
    description: "This value might escape its scope"
  },
  [Code.Undefined]: {
    title: "Undefined",
    description: "This hasn't been defined yet"
  },
  [Code.NotExported]: {
    title: "Not exported",
    description: "This isn't exported from the module"
  },
  [Code.AlreadyImported]: {
    title: "Already imported",
    description: "You've already imported this module"
  },
  [Code.NonExhaustive]: {
    title: "Non-exhaustive match",
    description: "This match doesn't cover all cases"
  },
  [Code.UnreachableCase]: {
    title: "Unreachable case",
    description: "This case can never be reached"
  },
  [Code.BackendError]: {
    title: "Backend error",
    description: "The backend encountered an error"
  },
  [Code.LinkError]: {
    title: "Link error",
    description: "The linker encountered an error"
  },
  [Code.PkgConflict]: {
    title: "Dependency conflict",
    description: "Two dependencies require incompatible versions of the same package"
  },
  [Code.PkgHashMismatch]: {
    title: "Hash mismatch",
    description: "The downloaded content doesn't match the expected hash. The cache may be tampered."
  },
  [Code.PkgNotFound]: {
    title: "Package not found",
    description: "The requested dependency could not be found or fetched"
  },
  [Code.ErrorContext]: {
    title: "Error context",
    description: "Additional context attached to this error chain"
  },
  [Code.UncaughtError]: {
    title: "Uncaught error",
    description: "This error must be handled or propagated"
  },
  [Code.TestFailed]: {
    title: "Test failed",
    description: "The test block encountered a runtime failure"
  }
};

export function render(msg: Message, source: string): string {
  const info = codeMessages[msg.code] || { title: "Error", description: "Something went wrong" };
  let out = "";
  
  // Error header with color
  out += `${colors.bold}${colors.brightRed}error${colors.reset}`;
  out += `${colors.dim}[TRATIO${msg.code.toString().padStart(4, "0")}]${colors.reset}`;
  out += `: ${colors.bold}${info.title}${colors.reset}\n`;
  out += `  ${colors.dim}${info.description}${colors.reset}\n\n`;
  
  // Location
  out += `  ${colors.cyan}-->${colors.reset} ${colors.dim}line ${msg.span.line}, column ${msg.span.col}${colors.reset}\n`;
  out += `   ${colors.dim}|${colors.reset}\n`;
  
  // Show source context (3 lines before, the error line, 2 lines after)
  const lines = source.split("\n");
  const errorLine = msg.span.line - 1;
  const startLine = Math.max(0, errorLine - 2);
  const endLine = Math.min(lines.length, errorLine + 3);
  
  for (let i = startLine; i < endLine; i++) {
    const lineNum = i + 1;
    const line = lines[i] || "";
    const isErrorLine = i === errorLine;
    
    // Line number
    const lineNumStr = lineNum.toString().padStart(3, " ");
    if (isErrorLine) {
      out += `  ${colors.brightRed}>${colors.reset} ${colors.bold}${lineNumStr}${colors.reset} ${colors.dim}|${colors.reset} `;
    } else {
      out += `   ${lineNumStr} ${colors.dim}|${colors.reset} `;
    }
    
    // Line content with highlighting
    if (isErrorLine) {
      out += `${colors.brightWhite}${line}${colors.reset}\n`;
      // Error marker
      const col = Math.max(0, msg.span.col - 1);
      const length = Math.max(1, msg.span.end - msg.span.start);
      const marker = " ".repeat(col) + "^".repeat(Math.min(length, line.length - col));
      out += `     ${colors.dim}|${colors.reset} ${colors.brightRed}${marker}${colors.reset}`;
      // Error message
      out += ` ${colors.brightRed}${msg.text}${colors.reset}\n`;
    } else {
      out += `${colors.dim}${line}${colors.reset}\n`;
    }
  }
  out += `   ${colors.dim}|${colors.reset}\n`;
  
  // Notes
  if (msg.notes.length > 0) {
    for (const n of msg.notes) {
      out += `  ${colors.cyan}note${colors.reset}: ${n.text}\n`;
      if (n.fix) {
        out += `  ${colors.green}help${colors.reset}: ${n.fix}\n`;
      }
    }
    out += "\n";
  }
  
  // Suggestion
  if (msg.suggestion) {
    out += `  ${colors.brightYellow}suggestion${colors.reset}: ${msg.suggestion}\n\n`;
  }
  
  // Related spans
  if (msg.relatedSpans && msg.relatedSpans.length > 0) {
    for (const rel of msg.relatedSpans) {
      out += `  ${colors.magenta}related${colors.reset}: ${rel.text} at line ${rel.span.line}, column ${rel.span.col}\n`;
    }
    out += "\n";
  }
  
  return out;
}