import { AlertTriangle, ArrowLeft, Braces, Check, CheckCircle2, Copy, ExternalLink, GitCompare, GitFork, Maximize2, Network, PackageOpen, Search, ShieldCheck, X, XCircle } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import { Markdown } from "../components/markdown";
import { item as loadItem, type Package, type VersionSummary } from "../utils/registry";
import { date, displayPackageName } from "../utils/format";

type DetailProps = {
  name: string;
  onBack: () => void;
  onTag: (tag: string) => void;
};

export default function Detail({ name, onBack, onTag }: DetailProps) {
  const [item, setItem] = useState<Package>();
  const [previous, setPrevious] = useState<Package>();
  const [versions, setVersions] = useState<VersionSummary[]>([]);
  const [version, setVersion] = useState("");
  const [error, setError] = useState("");
  const [copied, setCopied] = useState(false);
  const [apiQuery, setApiQuery] = useState("");
  const [apiKind, setApiKind] = useState<"all" | "function" | "type" | "constant" | "value">("all");
  const [readmeOpen, setReadmeOpen] = useState(false);
  const [readmeOverflow, setReadmeOverflow] = useState(false);
  const readmePreviewRef = useRef<HTMLDivElement>(null);
  const readmeDialogRef = useRef<HTMLDialogElement>(null);
  const readmeButtonRef = useRef<HTMLButtonElement>(null);
  const readme = useMemo(() => item?.readme.join("\n") ?? "", [item?.readme]);

  useEffect(() => {
    const controller = new AbortController();
    setItem(undefined);
    setError("");
    setReadmeOpen(false);
    void loadItem(name, controller.signal, version || undefined)
      .then((result) => {
        setItem(result.package);
        setVersions(result.versions);
        const index = result.versions.findIndex((entry) => entry.version === result.package.version);
        const prior = result.versions[index + 1];
        if (prior) void loadItem(name, controller.signal, prior.version).then((value) => setPrevious(value.package));
        else setPrevious(undefined);
      })
      .catch((reason: unknown) => {
        if (!(reason instanceof DOMException && reason.name === "AbortError")) setError(reason instanceof Error ? reason.message : "Package unavailable");
      });
    return () => controller.abort();
  }, [name, version]);

  useEffect(() => {
    const preview = readmePreviewRef.current;
    if (!preview) return;
    const measure = () => setReadmeOverflow(preview.scrollHeight > preview.clientHeight + 1);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(preview);
    return () => observer.disconnect();
  }, [readme]);

  useEffect(() => {
    const dialog = readmeDialogRef.current;
    if (!dialog) return;
    if (readmeOpen && !dialog.open) dialog.showModal();
    if (!readmeOpen && dialog.open) dialog.close();
  }, [readmeOpen]);

  if (error) {
    return <div className="grid min-h-full place-items-center p-6 text-center"><div><PackageOpen className="mx-auto text-[#555]" /><p className="mt-3 text-sm text-[#aaa]">{error}</p><button className="mt-3 text-xs text-[#60D5DF]" type="button" onClick={onBack}>Return to packages</button></div></div>;
  }

  if (!item) {
    return <div className="mx-auto max-w-260 animate-pulse px-6 py-9"><div className="h-5 w-28 rounded bg-[#171717]" /><div className="mt-9 h-11 w-72 rounded bg-[#171717]" /><div className="mt-8 h-30 rounded-xl bg-[#111]" /></div>;
  }

  const copy = async () => {
    await navigator.clipboard.writeText(item.install);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1600);
  };
  const changes = previous ? differences(item, previous) : ["Initial indexed release"];
  const normalizedApiQuery = apiQuery.trim().toLowerCase();
  const apiModules = (item.api?.modules ?? []).map((module) => ({
    ...module,
    items: module.items.filter((entry) => (apiKind === "all" || entry.kind === apiKind) && (!normalizedApiQuery ||
      `${module.name} ${entry.kind} ${entry.name} ${entry.declaration}`.toLowerCase().includes(normalizedApiQuery))),
  })).filter((module) => module.items.length > 0 || (!normalizedApiQuery && module.summary));
  const apiCount = (item.api?.modules ?? []).reduce((count, module) => count + module.items.length, 0);

  return (
    <>
    <article className="mx-auto w-full max-w-260 px-4 py-6 sm:px-7 sm:py-9">
      <button className="flex items-center gap-2 text-xs text-[#777] hover:text-[#f5f5f5]" type="button" onClick={onBack}>
        <ArrowLeft size={14} /> Packages
      </button>

      <header className="mt-7 border-b border-[#242424] pb-7">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <p className="flex items-center gap-2 font-mono text-[10px] tracking-[0.14em] text-[#60D5DF] uppercase">{item.category}{item.kind === "standard" && <span className="rounded border border-[#285A5E] px-1.5 py-0.5 text-[7px]">Bundled</span>}</p>
            <h1 className="mt-2 font-mono text-3xl font-semibold text-[#f5f5f5]">{displayPackageName(item.name)}</h1>
            <p className="mt-3 max-w-160 text-sm leading-6 text-[#929292]">{item.description}</p>
          </div>
          <label className="self-start">
            <span className="sr-only">Package version</span>
            <select className="rounded-lg border border-[#32747A] bg-[#112628] px-2.5 py-1.5 font-mono text-xs text-[#60D5DF] outline-none" value={item.version} onChange={(event) => setVersion(event.target.value)}>
              {versions.map((entry) => <option key={entry.version} value={entry.version}>{entry.version}</option>)}
            </select>
          </label>
        </div>
        <div className="mt-5 flex flex-wrap gap-1.5">
          {item.tags.map((tag) => <button key={tag} className="rounded-lg border border-[#292929] bg-[#141414] px-2 py-1 font-mono text-[10px] text-[#777] hover:text-[#60D5DF]" type="button" onClick={() => onTag(tag)}>{tag}</button>)}
        </div>
      </header>

      {item.deprecated && (
        <div className="mt-4 flex items-start gap-2 border-l-2 border-[#b78b2f] bg-[#17140d] px-3 py-2 text-xs text-[#c8ad73]">
          <AlertTriangle className="mt-0.5 shrink-0" size={13} />
          <span>{item.deprecated}</span>
        </div>
      )}

      <div className="grid gap-3 py-7 md:grid-cols-[1.2fr_0.8fr]">
        <section className="rounded-xl border border-[#292929] bg-[#111] p-4">
          <div className="mb-3 flex items-center justify-between">
            <h2 className="text-[10px] font-semibold tracking-[0.14em] text-[#777] uppercase">{item.kind === "standard" ? "Import" : "Install"}</h2>
            <span className="flex items-center gap-1.5 text-[10px] text-[#4EABB3]"><ShieldCheck size={11} /> Compatible</span>
          </div>
          <button className="flex w-full items-center justify-between rounded-lg border border-[#2b2b2b] bg-[#090909] px-3 py-2.5 text-left font-mono text-xs text-[#d6d6d6] hover:border-[#32747A]" type="button" onClick={() => void copy()} title="Copy install command">
            <span>{item.install}</span>
            {copied ? <Check size={14} className="text-[#60D5DF]" /> : <Copy size={14} className="text-[#666]" />}
          </button>
        </section>
        <section className="rounded-xl border border-[#292929] bg-[#111] p-4">
          <h2 className="text-[10px] font-semibold tracking-[0.14em] text-[#777] uppercase">Source</h2>
          <a className="mt-4 flex items-center justify-between text-xs text-[#aaa] no-underline hover:text-[#60D5DF]" href={item.repository} target="_blank" rel="noreferrer">
            <span className="flex items-center gap-2"><GitFork size={14} /> {item.owner.login}</span>
            <ExternalLink size={13} />
          </a>
        </section>
      </div>

      <div className="grid gap-9 border-t border-[#242424] py-7 lg:grid-cols-[minmax(0,1fr)_220px]">
        <section>
          <h2 className="text-[10px] font-semibold tracking-[0.14em] text-[#777] uppercase">About</h2>
          <div ref={readmePreviewRef} className={`package-readme-preview docs-prose ${readmeOverflow ? "is-truncated" : ""}`}>
            <Markdown source={readme} />
          </div>
          {readmeOverflow && <button ref={readmeButtonRef} className="package-readme-more" type="button" aria-haspopup="dialog" aria-expanded={readmeOpen} onClick={() => setReadmeOpen(true)}><Maximize2 size={12} /> See more</button>}
        </section>
        <aside className="border-t border-[#242424] pt-6 lg:border-t-0 lg:border-l lg:pt-0 lg:pl-6">
          <h2 className="text-[10px] font-semibold tracking-[0.14em] text-[#777] uppercase">Metadata</h2>
          <dl className="mt-4 space-y-3 text-[11px]">
            <div className="flex justify-between"><dt className="text-[#5f5f5f]">License</dt><dd className="font-mono text-[#aaa]">{item.license}</dd></div>
            <div className="flex justify-between"><dt className="text-[#5f5f5f]">Updated</dt><dd className="font-mono text-[#aaa]">{date(item.updated)}</dd></div>
          </dl>
        </aside>
      </div>

      <section className="border-t border-[#242424] py-7">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <h2 className="flex items-center gap-2 text-[10px] font-semibold tracking-[0.14em] text-[#777] uppercase"><Braces size={12} /> Public API</h2>
            <p className="mt-2 text-xs text-[#666]">{apiCount} public {apiCount === 1 ? "item" : "items"} across {item.api?.modules.length ?? 0} {(item.api?.modules.length ?? 0) === 1 ? "module" : "modules"}</p>
          </div>
          <label className="relative block w-full sm:w-64">
            <Search className="pointer-events-none absolute top-1/2 left-3 -translate-y-1/2 text-[#5f5f5f]" size={13} />
            <span className="sr-only">Search this package API</span>
            <input className="h-9 w-full rounded-lg border border-[#292929] bg-[#101010] pr-3 pl-8 font-mono text-[11px] text-[#ddd] outline-none placeholder:text-[#555] focus:border-[#32747A]" type="search" value={apiQuery} onChange={(event) => setApiQuery(event.target.value)} placeholder="Search functions and types" />
          </label>
        </div>

        <div className="mt-3 flex flex-wrap gap-1" role="group" aria-label="Public API kind">
          {(["all", "function", "type", "constant", "value"] as const).map((kind) => (
            <button key={kind} className={`rounded border px-2 py-1 font-mono text-[8px] capitalize ${apiKind === kind ? "border-[#32747A] bg-[#112628] text-[#60D5DF]" : "border-[#292929] text-[#666] hover:text-[#bbb]"}`} type="button" onClick={() => setApiKind(kind)}>{kind}</button>
          ))}
        </div>

        {apiModules.length ? (
          <div className="mt-5 divide-y divide-[#242424] border-y border-[#242424]">
            {apiModules.map((module) => (
              <section key={module.path} className="grid gap-4 py-5 md:grid-cols-[180px_minmax(0,1fr)]">
                <header>
                  <h3 className="font-mono text-xs font-semibold text-[#d8d8d8]">{displayPackageName(module.name)}</h3>
                  <p className="mt-1 break-all font-mono text-[9px] text-[#555]">{module.path}</p>
                  {module.summary && <p className="mt-3 text-[11px] leading-5 text-[#777]">{module.summary}</p>}
                </header>
                <div className="min-w-0 divide-y divide-[#202020]">
                  {module.items.map((entry) => (
                    <article key={`${entry.kind}:${entry.name}:${entry.declaration}`} className="py-3 first:pt-0 last:pb-0">
                      <div className="flex items-center gap-2">
                        <span className="rounded border border-[#285A5E] bg-[#102124] px-1.5 py-0.5 font-mono text-[8px] text-[#4EABB3] uppercase">{entry.kind}</span>
                        <h4 className="font-mono text-xs text-[#ededed]">{entry.name}</h4>
                      </div>
                      <pre className="mt-2 overflow-x-auto rounded-md bg-[#0b0b0b] px-3 py-2 font-mono text-[10px] leading-5 text-[#aaa]"><code>{entry.declaration}</code></pre>
                      {entry.documentation && <p className="mt-2 text-[11px] leading-5 text-[#777]">{entry.documentation}</p>}
                    </article>
                  ))}
                </div>
              </section>
            ))}
          </div>
        ) : <p className="mt-5 border-y border-[#242424] py-6 text-xs text-[#5f5f5f]">{normalizedApiQuery ? "No public API items match this search." : "This release exposes no indexed public API."}</p>}
      </section>

      <section className="border-t border-[#242424] py-6">
        <h2 className="flex items-center gap-2 text-[10px] font-semibold tracking-[0.14em] text-[#777] uppercase"><Network size={12} /> Dependency graph</h2>
        {item.dependencies.length ? (
          <div className="mt-4 divide-y divide-[#222] border-y border-[#222]">
            {item.dependencies.map((dependency) => <div key={dependency.name} className="grid grid-cols-[minmax(0,1fr)_auto_auto] items-center gap-3 py-2.5 font-mono text-xs"><span className="text-[#555]">{displayPackageName(item.name)} <span className="text-[#60D5DF]">-&gt;</span> <span className="text-[#d4d4d4]">{displayPackageName(dependency.name)}</span></span><span className="text-[9px] text-[#666]">{dependency.kind ?? "runtime"}</span><span className="text-[#777]">{dependency.version}</span></div>)}
          </div>
        ) : <p className="mt-4 text-xs text-[#5f5f5f]">No runtime dependencies.</p>}
      </section>

      <div className="grid border-t border-[#242424] md:grid-cols-2 md:divide-x md:divide-[#242424]">
        <section className="py-6 md:pr-6">
          <h2 className="flex items-center gap-2 text-[10px] font-semibold tracking-[0.14em] text-[#777] uppercase"><ShieldCheck size={12} /> Platform compatibility</h2>
          <div className="mt-4 grid grid-cols-2 gap-px overflow-hidden rounded-lg border border-[#242424] bg-[#242424]">
            {["linux", "macos", "windows", "wasm"].map((platform) => {
              const supported = item.platforms.includes("all") || item.platforms.includes(platform);
              return <div key={platform} className="flex items-center justify-between bg-[#101010] px-3 py-2 text-[11px]"><span className="capitalize text-[#888]">{platform}</span>{supported ? <CheckCircle2 size={12} className="text-[#4EABB3]" /> : <XCircle size={12} className="text-[#4f4f4f]" />}</div>;
            })}
          </div>
        </section>
        <section className="border-t border-[#242424] py-6 md:border-t-0 md:pl-6">
          <h2 className="flex items-center gap-2 text-[10px] font-semibold tracking-[0.14em] text-[#777] uppercase"><GitCompare size={12} /> Version history</h2>
          <div className="mt-4 space-y-2">
            {versions.map((entry) => <button key={entry.version} className={`flex w-full items-center justify-between rounded-md px-2 py-1.5 text-left ${entry.version === item.version ? "bg-[#112628] text-[#60D5DF]" : "text-[#777] hover:bg-[#141414]"}`} type="button" onClick={() => setVersion(entry.version)}><span className="font-mono text-[11px]">{entry.version}</span><span className="text-[9px]">{entry.updated}</span></button>)}
          </div>
          <div className="mt-4 border-t border-[#222] pt-3">
            {changes.map((change) => <p key={change} className="mt-1 text-[10px] text-[#777]"><span className="mr-2 text-[#60D5DF]">+</span>{change}</p>)}
          </div>
        </section>
      </div>
    </article>
    <dialog
      ref={readmeDialogRef}
      className="package-readme-dialog"
      aria-labelledby="package-readme-title"
      onClose={() => {
        setReadmeOpen(false);
        requestAnimationFrame(() => readmeButtonRef.current?.focus());
      }}
      onClick={(event) => { if (event.target === event.currentTarget) setReadmeOpen(false); }}
    >
      <div className="package-readme-modal">
        <header>
          <div>
            <p>Package README</p>
            <h2 id="package-readme-title">{displayPackageName(item.name)} <span>{item.version}</span></h2>
          </div>
          <button type="button" onClick={() => setReadmeOpen(false)} title="Close README" aria-label="Close README"><X size={16} /></button>
        </header>
        <div className="package-readme-body docs-prose">
          <Markdown source={readme} />
        </div>
      </div>
    </dialog>
    </>
  );
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
