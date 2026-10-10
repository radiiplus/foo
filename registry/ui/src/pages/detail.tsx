import { AlertTriangle, ArrowLeft, ArrowRight, BookOpen, Check, ChevronRight, Code2, Copy, ExternalLink, FileCode2, GitFork, History, LayoutGrid, PackageOpen, Search, X } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import { Code } from "../components/code";
import { PackageArtwork } from "../components/package-artwork";
import { Markdown } from "../components/markdown";
import { item as loadItem, type Package, type PublicApiItem, type VersionSummary } from "../utils/registry";
import { date, displayPackageName } from "../utils/format";
import { seo } from "../utils/seo";

type DetailProps = {
  name: string;
  backLabel: string;
  onBack: () => void;
  onTag: (tag: string) => void;
};

type View = "api" | "docs" | "source" | "releases";
type ApiRow = { id: string; module: string; path: string; entry: PublicApiItem };
const views = [
  { id: "api", label: "Cards", icon: LayoutGrid },
  { id: "docs", label: "Documentation", icon: BookOpen },
  { id: "source", label: "Source code", icon: Code2 },
  { id: "releases", label: "Releases", icon: History },
] satisfies { id: View; label: string; icon: typeof LayoutGrid }[];
const kinds = ["all", "function", "type", "constant", "value"] as const;

export default function Detail({ name, backLabel, onBack, onTag }: DetailProps) {
  const [item, setItem] = useState<Package>();
  const [previous, setPrevious] = useState<Package>();
  const [versions, setVersions] = useState<VersionSummary[]>([]);
  const [version, setVersion] = useState("");
  const [error, setError] = useState("");
  const [copied, setCopied] = useState("");
  const [apiQuery, setApiQuery] = useState("");
  const [apiKind, setApiKind] = useState<(typeof kinds)[number]>("all");
  const [view, setView] = useState<View>(() => locationView());
  const [sourcePath, setSourcePath] = useState(() => new URLSearchParams(window.location.search).get("file") ?? "");
  const [symbolId, setSymbolId] = useState(() => new URLSearchParams(window.location.search).get("api") ?? "");
  const dialogRef = useRef<HTMLDialogElement>(null);
  const sourceDialogRef = useRef<HTMLDialogElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const sourceTriggerRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    const controller = new AbortController();
    setItem(undefined);
    setError("");
    void loadItem(name, controller.signal, version || undefined)
      .then((result) => {
        setItem(result.package);
        setVersions(result.versions);
        const index = result.versions.findIndex((entry) => entry.version === result.package.version);
        const prior = result.versions[index + 1];
        if (prior) {
          void loadItem(name, controller.signal, prior.version)
            .then((value) => setPrevious(value.package))
            .catch(() => setPrevious(undefined));
        } else setPrevious(undefined);
      })
      .catch((reason: unknown) => {
        if (!(reason instanceof DOMException && reason.name === "AbortError")) setError(reason instanceof Error ? reason.message : "Package unavailable");
      });
    return () => controller.abort();
  }, [name, version]);

  useEffect(() => {
    const sync = () => {
      setView(locationView());
      setSymbolId(new URLSearchParams(window.location.search).get("api") ?? "");
      setSourcePath(new URLSearchParams(window.location.search).get("file") ?? "");
    };
    window.addEventListener("popstate", sync);
    return () => window.removeEventListener("popstate", sync);
  }, []);

  useEffect(() => {
    if (!item) return;
    seo({
      title: `${displayPackageName(item.name)} - FOO Package Registry`,
      description: item.description || `Versions, API, and documentation for ${displayPackageName(item.name)}.`,
      path: `/package/${encodeURIComponent(item.name)}`,
    });
  }, [item]);

  const rows = useMemo<ApiRow[]>(() => (item?.api.modules ?? []).flatMap((module) =>
    module.items.map((entry, index) => ({
      id: `${module.path}:${entry.kind}:${entry.name}:${index}`,
      module: module.name,
      path: module.path,
      entry,
    }))), [item]);
  const selected = rows.find((row) => row.id === symbolId);
  const matches = rows.filter((row) => {
    const needle = apiQuery.trim().toLowerCase();
    return (apiKind === "all" || row.entry.kind === apiKind) &&
      (!needle || `${row.module} ${row.entry.kind} ${row.entry.name} ${row.entry.declaration} ${row.entry.documentation}`.toLowerCase().includes(needle));
  });
  const selectedSource = item?.source.files.find((file) => file.path === sourcePath);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (selected && view === "api" && !dialog.open) dialog.showModal();
    if ((!selected || view !== "api") && dialog.open) dialog.close();
  }, [selected, view]);

  useEffect(() => {
    const dialog = sourceDialogRef.current;
    if (!dialog) return;
    if (selectedSource && view === "source" && !dialog.open) dialog.showModal();
    if ((!selectedSource || view !== "source") && dialog.open) dialog.close();
  }, [selectedSource, view]);

  const navigateView = (next: View, symbol = "", replace = false) => {
    const url = new URL(window.location.href);
    url.searchParams.set("view", next);
    if (symbol) url.searchParams.set("api", symbol);
    else url.searchParams.delete("api");
    url.searchParams.delete("file");
    window.history[replace ? "replaceState" : "pushState"](window.history.state ?? {}, "", `${url.pathname}${url.search}`);
    setView(next);
    setSymbolId(symbol);
    setSourcePath("");
  };

  const openSource = (path: string, button?: HTMLButtonElement) => {
    const url = new URL(window.location.href);
    url.searchParams.set("view", "source");
    url.searchParams.delete("api");
    url.searchParams.set("file", path);
    window.history.pushState(window.history.state ?? {}, "", `${url.pathname}${url.search}`);
    sourceTriggerRef.current = button ?? null;
    setView("source");
    setSymbolId("");
    setSourcePath(path);
  };

  const closeSource = () => {
    const url = new URL(window.location.href);
    url.searchParams.delete("file");
    window.history.replaceState(window.history.state ?? {}, "", `${url.pathname}${url.search}`);
    setSourcePath("");
    requestAnimationFrame(() => sourceTriggerRef.current?.focus());
  };

  const closeSymbol = () => {
    navigateView("api", "", true);
    requestAnimationFrame(() => triggerRef.current?.focus());
  };

  const copy = async (value: string, key: string) => {
    await navigator.clipboard.writeText(value);
    setCopied(key);
    window.setTimeout(() => setCopied((current) => current === key ? "" : current), 1500);
  };

  if (error) {
    return <div className="registry-empty"><PackageOpen size={24} /><p>{error}</p><button type="button" onClick={onBack}>Return to libraries</button></div>;
  }
  if (!item) return <div className="registry-loading">Loading package...</div>;

  const readme = item.readme.join("\n");
  const changes = previous ? differences(item, previous) : ["Initial indexed release"];

  return (
    <>
      <article className="registry-detail">
        <button className="registry-back" type="button" onClick={onBack}><ArrowLeft size={15} /> {backLabel}</button>

        <header className="registry-package-head">
          <div className="registry-package-main">
            <div className={`registry-package-icon${item.icon ? " custom" : ""}`} aria-hidden="true"><PackageArtwork name={item.name} kind={item.kind} icon={item.icon} size={24} /></div>
            <div className="registry-package-identity">
            <p className="registry-kicker">{item.kind === "standard" ? "FOO / Standard library" : `FOO / ${item.category}`}</p>
            <div className="registry-title-line">
              <h1>{displayPackageName(item.name)}</h1>
              <label className="registry-version-select">
                <span className="sr-only">Package version</span>
                <select value={item.version} onChange={(event) => setVersion(event.target.value)}>
                  {versions.map((entry) => <option key={entry.version} value={entry.version}>{entry.version}</option>)}
                </select>
              </label>
            </div>
            <p className="registry-package-description">{item.description}</p>
            </div>
          </div>
          <div className="registry-install">
            <span>{item.kind === "standard" ? "IMPORT" : "INSTALL"}</span>
            <div><code>{item.install}</code><button type="button" onClick={() => void copy(item.install, "install")} title="Copy install command" aria-label="Copy install command">{copied === "install" ? <Check size={15} /> : <Copy size={15} />}</button></div>
          </div>
        </header>

        {item.deprecated && <p className="registry-warning"><AlertTriangle size={15} />{item.deprecated}</p>}

        <nav className="registry-view-tabs" aria-label="Package views">{views.map((option) => <button key={option.id} type="button" className={view === option.id ? "active" : ""} aria-current={view === option.id ? "page" : undefined} onClick={() => navigateView(option.id)}><option.icon size={14} /><span>{option.label}</span></button>)}</nav>

        {view === "api" && <div className="registry-detail-grid registry-cards-view">
          <section className="registry-api-view">
            <div className="registry-section-heading"><div><h2>Public surface</h2><p className="registry-muted">{matches.length} of {rows.length} symbols</p></div></div>
            <div className="registry-api-tools">
              <label className="registry-api-search"><Search size={15} /><span className="sr-only">Search this package API</span><input type="search" value={apiQuery} onChange={(event) => setApiQuery(event.target.value)} placeholder="Find a symbol or signature" /></label>
              <div className="registry-kind-control" role="group" aria-label="API symbol kind">{kinds.map((kind) => <button key={kind} type="button" className={apiKind === kind ? "active" : ""} aria-pressed={apiKind === kind} onClick={() => setApiKind(kind)}>{kind}</button>)}</div>
            </div>
            {matches.length ? <div className="registry-symbol-masonry">{matches.map((row) => <SymbolCard key={row.id} row={row} onOpen={(button) => { triggerRef.current = button; navigateView("api", row.id); }} />)}</div>
              : <p className="registry-api-empty">{rows.length ? "No symbols match these filters." : "This release has no indexed public symbols."}</p>}
          </section>
          <aside className="registry-facts" aria-label="Package details">
            <h2>Package details</h2>
            <dl>
              <div><dt>License</dt><dd>{item.license}</dd></div>
              <div><dt>Updated</dt><dd>{date(item.updated)}</dd></div>
              <div><dt>Platforms</dt><dd>{item.platforms.join(", ") || "Unspecified"}</dd></div>
              <div><dt>Compatibility</dt><dd>{item.compatible ? "Compatible" : "Not verified"}</dd></div>
            </dl>
            <a href={item.repository} target="_blank" rel="noreferrer"><GitFork size={14} />{item.owner.login}<ExternalLink size={13} /></a>
            {item.tags.length > 0 && <div className="registry-tags">{item.tags.map((tag) => <button key={tag} type="button" onClick={() => onTag(tag)}>{tag}</button>)}</div>}
            {item.dependencies.length > 0 && <div className="registry-dependencies"><h3>Dependencies</h3>{item.dependencies.map((dependency) => <div key={`${dependency.name}:${dependency.kind}`}><span>{dependency.name}</span><code>{dependency.version}</code></div>)}</div>}
          </aside>
        </div>}

        {view === "docs" && <div className="registry-docs-view">
          {selected && <section className="registry-full-reference">
            <div className="registry-section-heading"><div><p className="registry-kicker">{selected.module} / {selected.entry.kind}</p><h2>{selected.entry.name}</h2></div><button type="button" onClick={() => navigateView("api", selected.id)}>API index <ArrowRight size={15} /></button></div>
            <SymbolReference row={selected} packageItem={item} copied={copied} onCopy={copy} onSource={openSource} showSource />
          </section>}
          <section className="registry-section"><p className="registry-kicker">Package documentation</p><h2>{displayPackageName(item.name)} README</h2>
            {readme ? <div className="docs-prose registry-readme"><Markdown source={readme} /></div> : <p className="registry-muted">No README was published for this release.</p>}
          </section>
        </div>}

        {view === "source" && <section className="registry-source-view">
          <div className="registry-section-heading"><div><h2>Source code</h2><p className="registry-muted">{item.source.files.length} {item.source.files.length === 1 ? "file" : "files"} in this release</p></div></div>
          {item.source.files.length ? <div className="registry-source-grid">{item.source.files.map((file) => <button key={file.path} className="registry-source-card" type="button" onClick={(event) => openSource(file.path, event.currentTarget)}><span><FileCode2 size={18} /><ArrowRight size={14} /></span><strong>{file.path}</strong><small>{file.content.split(/\r?\n/).length} lines</small></button>)}</div>
            : <p className="registry-muted">No source files were published for this release.</p>}
        </section>}

        {view === "releases" && <div className="registry-releases-view">
          <div className="registry-section-heading"><div><p className="registry-kicker">Release history</p><h2>Versions</h2></div></div>
          <div className="registry-release-list">{versions.map((entry) => <button key={entry.version} type="button" className={item.version === entry.version ? "active" : ""} onClick={() => setVersion(entry.version)}><span><strong>{entry.version}</strong><small>{entry.deprecated || (entry.version === item.version ? "Selected release" : "")}</small></span><span>{date(entry.updated)}</span><ChevronRight size={15} /></button>)}</div>
          <section className="registry-section"><p className="registry-kicker">Compared with previous release</p><h2>Indexed changes</h2>{changes.map((change) => <p className="registry-change" key={change}>{change}</p>)}</section>
        </div>}
      </article>

      <dialog ref={dialogRef} className="registry-symbol-dialog" aria-labelledby="registry-symbol-title" onCancel={(event) => { event.preventDefault(); closeSymbol(); }} onClick={(event) => { if (event.target === event.currentTarget) closeSymbol(); }}>
        {selected && <div className="registry-symbol-sheet">
          <header><div><p className="registry-kicker">{selected.module} / {selected.entry.kind}</p><h2 id="registry-symbol-title">{selected.entry.name}</h2></div><button type="button" onClick={closeSymbol} title="Close symbol detail" aria-label="Close symbol detail"><X size={18} /></button></header>
          <div className="registry-symbol-body"><SymbolReference row={selected} packageItem={item} copied={copied} onCopy={copy} onSource={openSource} /></div>
          <footer><button type="button" onClick={() => navigateView("docs", selected.id)}><FileCode2 size={15} /> Full reference <ArrowRight size={15} /></button></footer>
        </div>}
      </dialog>
      <dialog ref={sourceDialogRef} className="registry-source-dialog" aria-labelledby="registry-source-dialog-title" onCancel={(event) => { event.preventDefault(); closeSource(); }} onClick={(event) => { if (event.target === event.currentTarget) closeSource(); }}>
        {selectedSource && <div className="registry-source-popup"><header><div><p className="registry-kicker">Source file</p><h2 id="registry-source-dialog-title">{selectedSource.path}</h2></div><button type="button" onClick={closeSource} title="Close source file" aria-label="Close source file"><X size={18} /></button></header><div className="registry-source-popup-code"><Code code={selectedSource.content} language="foo" /></div></div>}
      </dialog>
    </>
  );
}

function SymbolCard({ row, onOpen }: { row: ApiRow; onOpen: (button: HTMLButtonElement) => void }) {
  return <button className="registry-symbol-card" type="button" onClick={(event) => onOpen(event.currentTarget)}>
    <span className="registry-symbol-card-top"><span className="registry-symbol-kind">{row.entry.kind}</span><ChevronRight size={14} /></span>
    <strong>{row.entry.name}</strong>
    <span className="registry-symbol-card-description">{row.entry.documentation || row.entry.declaration}</span>
    <span className="registry-symbol-card-module">{displayPackageName(row.module)}</span>
  </button>;
}

function SymbolReference({ row, packageItem, copied, onCopy, onSource, showSource = false }: {
  row: ApiRow;
  packageItem: Package;
  copied: string;
  onCopy: (value: string, key: string) => Promise<void>;
  onSource: (path: string) => void;
  showSource?: boolean;
}) {
  const example = readmeExample(packageItem.readme.join("\n"), row.entry.name);
  const source = packageItem.source.files.find((file) => file.path === row.path);
  const excerpt = source && sourceExcerpt(source.content, row.entry);
  return <div className="registry-reference">
    <section><div className="registry-reference-label"><h3>Declaration</h3><button type="button" title="Copy signature" aria-label="Copy signature" onClick={() => void onCopy(row.entry.declaration, `signature:${row.id}`)}>{copied === `signature:${row.id}` ? <Check size={15} /> : <Copy size={15} />}</button></div><pre><code>{row.entry.declaration}</code></pre></section>
    <section><h3>Notes</h3><p>{row.entry.documentation || "No additional notes were published for this symbol."}</p></section>
    {example && <section><div className="registry-reference-label"><h3>Example from README</h3><button type="button" title="Copy example" aria-label="Copy example" onClick={() => void onCopy(example.code, `example:${row.id}`)}>{copied === `example:${row.id}` ? <Check size={15} /> : <Copy size={15} />}</button></div><pre><code>{example.code}</code></pre></section>}
    <section><h3>Source</h3><p className="registry-source-path">{row.path}</p>{!showSource && excerpt && <div className="registry-source-excerpt"><h4>Source excerpt</h4><Code code={excerpt} language="foo" /></div>}{source && <button className="registry-open-source" type="button" onClick={() => onSource(source.path)}>{showSource ? "Open source file" : "View full source"}<ArrowRight size={13} /></button>}</section>
  </div>;
}

function readmeExample(readme: string, name: string) {
  const blocks = [...readme.matchAll(/```([\w-]*)\s*\r?\n([\s\S]*?)```/g)];
  const match = blocks.find((block) => block[2].includes(name));
  return match ? { code: match[2].trim() } : undefined;
}

function sourceExcerpt(content: string, entry: PublicApiItem) {
  const lines = content.split(/\r?\n/);
  const lead = entry.declaration.split("\n")[0].replace(/\s*[.{]\s*$/, "").slice(0, 50);
  const start = lines.findIndex((line) => line.trimStart().startsWith(lead));
  if (start < 0) return "";
  let end = start + 1;
  while (end < lines.length && end < start + 45 && !/^public\s+(?:use\s+"[^"]+"\s+)?(?:function|define|constant|dynamic)\b/.test(lines[end].trimStart())) end += 1;
  return lines.slice(start, end).join("\n").trim();
}

function locationView(): View {
  const params = new URLSearchParams(window.location.search);
  const value = params.get("view");
  if (value === "docs" || value === "source" || value === "releases") return value;
  return "api";
}

function differences(current: Package, previous: Package) {
  const changes: string[] = [];
  if (current.description !== previous.description) changes.push("Description updated");
  const before = new Set(previous.dependencies.map((entry) => entry.name));
  const after = new Set(current.dependencies.map((entry) => entry.name));
  const added = [...after].filter((name) => !before.has(name));
  const removed = [...before].filter((name) => !after.has(name));
  if (added.length) changes.push(`Added ${added.map(displayPackageName).join(", ")}`);
  if (removed.length) changes.push(`Removed ${removed.map(displayPackageName).join(", ")}`);
  const platforms = current.platforms.filter((platform) => !previous.platforms.includes(platform));
  if (platforms.length) changes.push(`Added ${platforms.join(", ")} support`);
  return changes.length ? changes : ["Metadata-only release"];
}
