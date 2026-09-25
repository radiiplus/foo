import { ArrowLeft, ArrowRight, BookOpen, Clock3, Menu, X } from "lucide-react";
import { Children, isValidElement, useEffect, useMemo, useState, type ReactNode } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

import { CodeBlock } from "../components/code-block";
import { chapterById, chapters, docHref } from "../content/docs";

type DocsProps = {
  chapterId: string;
  section?: string;
};

export default function Docs({ chapterId, section }: DocsProps) {
  const chapter = chapterById(chapterId);
  const [menuOpen, setMenuOpen] = useState(false);
  const index = chapters.indexOf(chapter);
  const previous = chapters[index - 1];
  const next = chapters[index + 1];
  const source = useMemo(() => removeTitle(chapter.source), [chapter.source]);
  const sections = useMemo(() => headings(source), [source]);
  const minutes = Math.max(2, Math.round(source.split(/\s+/).length / 210));

  useEffect(() => {
    document.title = `${chapter.title} - FOO Docs`;
    if (section) requestAnimationFrame(() => document.getElementById(section)?.scrollIntoView({ block: "start" }));
    else document.querySelector("main")?.scrollTo({ top: 0 });
    setMenuOpen(false);
    return () => { document.title = "FOO Registry"; };
  }, [chapter, section]);

  return (
    <div className="docs-shell">
      <button className="docs-mobile-menu" type="button" onClick={() => setMenuOpen((open) => !open)}>
        {menuOpen ? <X size={15} /> : <Menu size={15} />}
        Chapters
      </button>

      <aside className={`docs-rail ${menuOpen ? "is-open" : ""}`}>
        <a className="docs-rail-title" href="/docs/overview">
          <BookOpen size={16} />
          <span><strong>FOO Book</strong><small>Language documentation</small></span>
        </a>
        {["Start", "Build", "Master"].map((group) => (
          <section key={group}>
            <p>{group}</p>
            {chapters.filter((item) => item.group === group).map((item) => (
              <a key={item.id} className={item.id === chapter.id ? "active" : ""} href={`/docs/${item.id}`}>
                <span>{String(chapters.indexOf(item) + 1).padStart(2, "0")}</span>{item.shortTitle}
              </a>
            ))}
          </section>
        ))}
      </aside>

      <div className="docs-reading-pane">
        <article className="docs-article">
          <header className="docs-chapter-header">
            <div className="docs-kicker"><span>FOO BOOK</span><i />CHAPTER {String(index + 1).padStart(2, "0")}</div>
            <h1>{chapter.title}</h1>
            <p>{chapter.description}</p>
            <div className="docs-meta"><span><Clock3 size={12} />{minutes} min read</span><span>FOO 0.2</span></div>
          </header>

          <div className="docs-prose">
            <ReactMarkdown
              remarkPlugins={[remarkGfm]}
              components={{
                h1: ({ children }) => <h2 id={slugify(textOf(children))}>{children}</h2>,
                h2: ({ children }) => <h2 id={slugify(textOf(children))}>{children}</h2>,
                h3: ({ children }) => <h3 id={slugify(textOf(children))}>{children}</h3>,
                pre: ({ children }) => <>{children}</>,
                code: ({ className, children, ...props }) => {
                  const language = className?.match(/language-([\w-]+)/)?.[1];
                  const code = String(children).replace(/\n$/, "");
                  if (language || code.includes("\n")) return <CodeBlock code={code} language={language ?? "text"} />;
                  return <code {...props}>{children}</code>;
                },
                a: ({ href, children, ...props }) => {
                  const destination = docHref(href);
                  const external = destination?.startsWith("http");
                  return <a {...props} href={destination} target={external ? "_blank" : undefined} rel={external ? "noreferrer" : undefined}>{children}</a>;
                },
              }}
            >{source}</ReactMarkdown>
          </div>

          <nav className="docs-chapter-nav" aria-label="Chapter navigation">
            {previous ? <a href={`/docs/${previous.id}`}><ArrowLeft size={15} /><span><small>Previous</small>{previous.shortTitle}</span></a> : <span />}
            {next ? <a href={`/docs/${next.id}`}><span><small>Next</small>{next.shortTitle}</span><ArrowRight size={15} /></a> : <span />}
          </nav>
        </article>

        <aside className="docs-outline">
          <p>On this page</p>
          {sections.slice(0, 12).map((section) => <a key={section.id} className={section.depth === 3 ? "nested" : ""} href={`/docs/${chapter.id}?section=${section.id}`} onClick={() => scrollToSection(section.id)}>{section.label}</a>)}
          <div><span />FOO 0.2 documentation</div>
        </aside>
      </div>
    </div>
  );
}

function removeTitle(source: string) {
  return source.replace(/^\s*#\s+[^\n]+\r?\n+/, "").trim();
}

function headings(source: string) {
  return [...source.matchAll(/^(##|###)\s+(.+)$/gm)].map((match) => {
    const label = match[2].replace(/[`*_]/g, "").replace(/^\d+\.\s*/, "");
    return { depth: match[1].length, label, id: slugify(match[2]) };
  });
}

function slugify(value: string) {
  return value.toLowerCase().replace(/<[^>]+>/g, "").replace(/[`*_()]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

function textOf(node: ReactNode): string {
  return Children.toArray(node).map((item) => {
    if (typeof item === "string" || typeof item === "number") return String(item);
    return isValidElement<{ children?: ReactNode }>(item) ? textOf(item.props.children) : "";
  }).join("");
}

function scrollToSection(id: string) {
  window.setTimeout(() => document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" }), 0);
}
