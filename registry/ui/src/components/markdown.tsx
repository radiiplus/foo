import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

import { CodeBlock } from "./code-block";

type MarkdownProps = {
  source: string;
};

export function Markdown({ source }: MarkdownProps) {
  return (
    <ReactMarkdown
      remarkPlugins={[remarkGfm]}
      components={{
        h1: ({ children }) => <h2>{children}</h2>,
        pre: ({ children }) => <>{children}</>,
        code: ({ className, children, ...props }) => {
          const language = className?.match(/language-([\w-]+)/)?.[1];
          const code = String(children).replace(/\n$/, "");
          if (language || code.includes("\n")) return <CodeBlock code={code} language={language ?? "text"} />;
          return <code {...props}>{children}</code>;
        },
        a: ({ href, children, ...props }) => {
          const external = href?.startsWith("http");
          return <a {...props} href={href} target={external ? "_blank" : undefined} rel={external ? "noreferrer" : undefined}>{children}</a>;
        },
        img: ({ alt, ...props }) => <img {...props} alt={alt ?? ""} loading="lazy" />,
      }}
    >{source}</ReactMarkdown>
  );
}
