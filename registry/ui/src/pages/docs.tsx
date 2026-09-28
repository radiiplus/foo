import { ArrowLeft, ArrowRight, BookOpen, Clock3, Menu, Search, X } from "lucide-react";
import { Children, isValidElement, useEffect, useMemo, useState, type ReactNode } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

import manifest from "../../../../package.json";
import { Code } from "../components/code";
import { chapter, chapters, link } from "../content/docs";
import { seo } from "../utils/seo";

type Props = {
  id: string;
  section?: string;
};

export default function Docs({ id, section }: Props) {
  const page = chapter(id);
  const [menu, toggle] = useState(false);
  const [query, search] = useState("");
  const index = chapters.indexOf(page);
  const previous = chapters[index - 1];
  const next = chapters[index + 1];
  const source = useMemo(() => clean(page.source), [page.source]);
  const sections = useMemo(() => headings(source), [source]);
  const minutes = Math.max(2, Math.round(source.split(/\s+/).length / 210));

  useEffect(() => {
    seo({
      title: `${page.title} - FOO Docs`,
      description: page.description,
      path: `/docs/${page.id}`,
    });
    if (section) requestAnimationFrame(() => document.getElementById(section)?.scrollIntoView({ block: "start" }));
    else document.querySelector("main")?.scrollTo({ top: 0 });
    toggle(false);
    return undefined;
  }, [page, section]);

  return (
    <div className="docs-shell">
      <button className="docs-mobile-menu" type="button" onClick={() => toggle((open) => !open)}>
        {menu ? <X size={15} /> : <Menu size={15} />}
        Chapters
      </button>

      <aside className={`docs-rail ${menu ? "is-open" : ""}`}>
        <a className="docs-rail-title" href="/docs/overview">
          <BookOpen size={16} />
          <span><strong>FOO Book</strong><small>Language documentation</small></span>
        </a>
        <label className="docs-search">
          <Search size={13} />
          <input aria-label="Search documentation chapters" placeholder="Search chapters" value={query} onChange={(event) => search(event.target.value)} />
        </label>
        {(["Learn", "Build", "Reference"] as const).map((group) => {
          const term = query.trim().toLowerCase();
          const items = chapters.filter((item) => item.group === group &&
            (!term || `${item.title} ${item.description}`.toLowerCase().includes(term)));
          return items.length > 0 && (
          <section key={group}>
            <p>{group}</p>
            {items.map((item) => (
              <a key={item.id} className={item.id === page.id ? "active" : ""} href={`/docs/${item.id}`}>
                <span>{String(chapters.indexOf(item) + 1).padStart(2, "0")}</span>{item.short}
              </a>
            ))}
          </section>
        );})}
      </aside>

      <div className="docs-reading-pane">
        <article className="docs-article">
          <header className="docs-chapter-header">
            <div className="docs-kicker"><span>FOO BOOK</span><i />CHAPTER {String(index + 1).padStart(2, "0")}</div>
            <h1>{page.title}</h1>
            <p>{page.description}</p>
            <div className="docs-meta"><span><Clock3 size={12} />{minutes} min read</span><span>FOO {manifest.version}</span></div>
          </header>

          <div className="docs-prose">
            <ReactMarkdown
              remarkPlugins={[remarkGfm]}
              components={{
                h1: ({ children }) => <h2 id={slug(text(children))}>{children}</h2>,
                h2: ({ children }) => <h2 id={slug(text(children))}>{children}</h2>,
                h3: ({ children }) => <h3 id={slug(text(children))}>{children}</h3>,
                pre: ({ children }) => <>{children}</>,
                code: ({ className, children, ...props }) => {
                  const language = className?.match(/language-([\w-]+)/)?.[1];
                  const code = String(children).replace(/\n$/, "");
                  if (language || code.includes("\n")) return <Code code={code} language={language ?? "text"} />;
                  return <code {...props}>{children}</code>;
                },
                a: ({ href, children, ...props }) => {
                  const destination = link(href);
                  const external = destination?.startsWith("http");
                  return <a {...props} href={destination} target={external ? "_blank" : undefined} rel={external ? "noreferrer" : undefined}>{children}</a>;
                },
              }}
            >{source}</ReactMarkdown>
          </div>

          <nav className="docs-chapter-nav" aria-label="Chapter navigation">
            {previous ? <a href={`/docs/${previous.id}`}><ArrowLeft size={15} /><span><small>Previous</small>{previous.short}</span></a> : <span />}
            {next ? <a href={`/docs/${next.id}`}><span><small>Next</small>{next.short}</span><ArrowRight size={15} /></a> : <span />}
          </nav>
        </article>

        <aside className="docs-outline">
          <p>On this page</p>
          {sections.slice(0, 12).map((section) => <a key={section.id} className={section.depth === 3 ? "nested" : ""} href={`/docs/${page.id}?section=${section.id}`} onClick={() => scroll(section.id)}>{section.label}</a>)}
          <div><span />FOO {manifest.version} documentation</div>
        </aside>
      </div>
    </div>
  );
}

function clean(source: string) {
  return source.replace(/^\s*#\s+[^\n]+\r?\n+/, "").trim();
}

function headings(source: string) {
  return [...source.matchAll(/^(##|###)\s+(.+)$/gm)].map((match) => {
    const label = match[2].replace(/[`*_]/g, "").replace(/^\d+\.\s*/, "");
    return { depth: match[1].length, label, id: slug(match[2]) };
  });
}

function slug(value: string) {
  return value.toLowerCase().replace(/<[^>]+>/g, "").replace(/[`*_()]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

function text(node: ReactNode): string {
  return Children.toArray(node).map((item) => {
    if (typeof item === "string" || typeof item === "number") return String(item);
    return isValidElement<{ children?: ReactNode }>(item) ? text(item.props.children) : "";
  }).join("");
}

function scroll(id: string) {
  window.setTimeout(() => document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" }), 0);
}
