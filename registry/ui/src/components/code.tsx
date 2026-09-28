import { Check, Copy } from "lucide-react";
import Prism from "prismjs";
import { useEffect, useMemo, useState } from "react";

const word = (value: string) => new RegExp(`\\b(?:${value})\\b`);

Prism.languages.foo = {
  "doc-comment": { pattern: /--!.*$/m, greedy: true },
  comment: { pattern: /--.*$/m, greedy: true },
  string: { pattern: /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/, greedy: true },
  attribute: /#\[[^\]]+\]/,
  declaration: word("constant|dynamic|define|function|record|choice|public|packed|extern|use"),
  control: word("give|try|fallback|failable|when|otherwise|match|case|while|for|each|stop|skip|after|eval|native|asm"),
  connective: word("of|to"),
  type: word("integer|unsigned|decimal|boolean|byte|text|nothing|pointer|sequence|optional|vector|Error"),
  boolean: word("true|false|null"),
  operator: word("is|not|as|plus|subtract|multiply|divide|remainder|and|or|greater|less|than|equal"),
  number: /\b(?:0x[\da-f]+|0b[01]+|\d+(?:\.\d+)?)\b/i,
  function: /\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()/,
  property: { pattern: /(\.\s*)[A-Za-z_][A-Za-z0-9_]*/, lookbehind: true },
  punctuation: /[{}[\]().,:]/,
};

Prism.languages.shell = {
  comment: /#.*/,
  string: { pattern: /"(?:\\.|[^"\\])*"|'[^']*'/, greedy: true },
  command: /(^|[;&|]\s*)[a-z][\w.-]*/im,
  option: /(^|\s)--?[\w-]+/,
  variable: /\$[A-Za-z_][A-Za-z0-9_]*/,
  punctuation: /[|;&]/,
};

type Props = {
  code: string;
  language: string;
};

export function Code({ code, language }: Props) {
  const [copied, mark] = useState(false);
  const syntax = language === "sh" || language === "bash" || language === "shell" ? "shell" : language === "iv" ? "foo" : language;
  const grammar = Prism.languages[syntax];
  const html = useMemo(() => grammar ? Prism.highlight(code, grammar, syntax) : Prism.util.encode(code), [code, grammar, syntax]);

  useEffect(() => {
    if (!copied) return;
    const timeout = window.setTimeout(() => mark(false), 1600);
    return () => window.clearTimeout(timeout);
  }, [copied]);

  return (
    <figure className="docs-code">
      <figcaption>
        <span><i />{syntax === "foo" ? "FOO" : syntax || "text"}</span>
        <button
          type="button"
          onClick={() => void navigator.clipboard.writeText(code).then(() => mark(true))}
          title="Copy code"
          aria-label="Copy code"
        >
          {copied ? <Check size={13} /> : <Copy size={13} />}
        </button>
      </figcaption>
      <pre><code className={`language-${syntax}`} dangerouslySetInnerHTML={{ __html: String(html) }} /></pre>
    </figure>
  );
}
