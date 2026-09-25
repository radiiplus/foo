import { ChevronRight, Copy, FileJson, LibraryBig, Search } from "lucide-react";
import { useEffect, useMemo, useState } from "react";

import { standardIndex, standards, type PublicApiItem, type StandardPackage } from "../utils/registry";

type StandardProps = {
  onOpen: (name: string) => void;
};

type Match = { packageItem: StandardPackage; items: PublicApiItem[] };

export default function Standard({ onOpen }: StandardProps) {
  const [packages, setPackages] = useState<StandardPackage[]>([]);
  const [query, setQuery] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [copied, setCopied] = useState("");

  useEffect(() => {
    const controller = new AbortController();
    document.title = "Standard Library - FOO";
    void standards(controller.signal)
      .then(setPackages)
      .catch((reason: unknown) => {
        if (!(reason instanceof DOMException && reason.name === "AbortError")) setError("Standard library index unavailable");
      })
      .finally(() => setLoading(false));
    return () => {
      controller.abort();
      document.title = "FOO Registry";
    };
  }, []);

  const matches = useMemo<Match[]>(() => {
    const needle = query.trim().toLowerCase();
    return packages.flatMap((packageItem) => {
      const all = packageItem.api.modules.flatMap((module) => module.items);
      if (!needle || `${packageItem.name} ${packageItem.description}`.toLowerCase().includes(needle)) return [{ packageItem, items: all }];
      const items = all.filter((item) => `${item.kind} ${item.name} ${item.declaration} ${item.documentation}`.toLowerCase().includes(needle));
      return items.length ? [{ packageItem, items }] : [];
    });
  }, [packages, query]);

  const itemCount = packages.reduce((count, packageItem) => count + packageItem.api.modules.reduce((sum, module) => sum + module.items.length, 0), 0);
  const copy = async (value: string, key: string) => {
    await navigator.clipboard.writeText(value);
    setCopied(key);
    window.setTimeout(() => setCopied(""), 1400);
  };

  return (
    <div className="flex h-full min-h-0 flex-col overflow-hidden">
      <header className="shrink-0 border-b border-[#242424] px-4 py-3 sm:px-6">
        <div className="mx-auto flex max-w-[1400px] flex-col gap-3 md:flex-row md:items-center md:justify-between">
          <div className="min-w-0">
            <p className="font-mono text-[9px] tracking-[0.15em] text-[#60D5DF] uppercase">Reference / Standard</p>
            <div className="mt-1 flex flex-wrap items-baseline gap-x-3 gap-y-1">
              <h1 className="text-lg font-semibold text-[#f5f5f5]">Standard library</h1>
              <span className="font-mono text-[9px] text-[#666]">{packages.length} modules / {itemCount} public items{packages[0] ? ` / ${packages[0].owner.login}` : ""}</span>
            </div>
          </div>
          <div className="flex items-center gap-2">
            <label className="relative block min-w-0 flex-1 md:w-88">
              <Search className="pointer-events-none absolute top-1/2 left-3 -translate-y-1/2 text-[#666]" size={13} />
              <span className="sr-only">Search the standard library</span>
              <input className="h-9 w-full rounded-md border border-[#292929] bg-[#101010] pr-3 pl-8 font-mono text-[11px] text-[#ddd] outline-none placeholder:text-[#555] focus:border-[#32747a]" type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Module, function, type, or exact signature" />
            </label>
            <a className="grid size-9 shrink-0 place-items-center rounded-md border border-[#292929] bg-[#101010] text-[#777] hover:border-[#32747a] hover:text-[#60D5DF]" href={standardIndex()} target="_blank" rel="noreferrer" title="Machine-readable standard library index">
              <FileJson size={14} />
            </a>
          </div>
        </div>
      </header>

      {loading ? <div className="grid min-h-0 flex-1 place-items-center font-mono text-[10px] text-[#666]">Reading public interfaces...</div>
        : error ? <div className="grid min-h-0 flex-1 place-items-center text-sm text-[#ff7774]">{error}</div>
        : (
          <div className="mx-auto grid min-h-0 w-full max-w-[1400px] flex-1 md:grid-cols-[210px_minmax(0,1fr)]">
            <aside className="hidden min-h-0 overflow-y-auto border-r border-[#242424] px-3 py-3 md:block" aria-label="Standard modules">
              <p className="px-2 pb-2 font-mono text-[8px] tracking-[0.14em] text-[#555] uppercase">{matches.length} matching modules</p>
              {matches.map(({ packageItem, items }) => (
                <a key={packageItem.name} className="flex min-h-8 items-center justify-between rounded px-2 font-mono text-[10px] text-[#777] no-underline hover:bg-[#12191a] hover:text-[#60D5DF]" href={`#${anchor(packageItem.name)}`}>
                  <span>{packageItem.name.replace("std/", "")}</span><span className="text-[8px] text-[#4f4f4f]">{items.length}</span>
                </a>
              ))}
            </aside>

            <main className="min-h-0 overflow-y-auto px-4 pb-12 sm:px-6">
              {matches.length ? matches.map(({ packageItem, items }) => (
                <section id={anchor(packageItem.name)} key={packageItem.name} className="scroll-mt-3 border-b border-[#242424] py-6 first:pt-5">
                  <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
                    <div>
                      <button className="group flex items-center gap-1.5 font-mono text-base font-semibold text-[#ededed] hover:text-[#60D5DF]" type="button" onClick={() => onOpen(packageItem.name)}>
                        {packageItem.name}<ChevronRight size={14} className="text-[#555] group-hover:text-[#60D5DF]" />
                      </button>
                      <p className="mt-1 max-w-180 text-xs leading-5 text-[#777]">{packageItem.description}</p>
                    </div>
                    <button className="flex h-8 shrink-0 items-center gap-2 rounded-md border border-[#292929] bg-[#0d0d0d] px-2.5 font-mono text-[10px] text-[#aaa] hover:border-[#32747a] hover:text-white" type="button" onClick={() => void copy(packageItem.install, packageItem.name)} title="Copy import statement">
                      <code>{packageItem.install}</code><Copy size={11} className={copied === packageItem.name ? "text-[#60D5DF]" : "text-[#555]"} />
                    </button>
                  </div>

                  <div className="mt-4 divide-y divide-[#202020] border-y border-[#202020]">
                    {items.map((item) => (
                      <article key={`${item.kind}:${item.name}:${item.declaration}`} className="grid gap-2 py-3 lg:grid-cols-[150px_minmax(0,1fr)] lg:gap-4">
                        <div className="flex items-center gap-2 self-start">
                          <span className="w-13 font-mono text-[8px] text-[#4eabb3] uppercase">{item.kind}</span>
                          <strong className="font-mono text-[11px] font-medium text-[#ddd]">{item.name}</strong>
                        </div>
                        <div className="min-w-0">
                          <code className="block overflow-x-auto whitespace-pre rounded bg-[#0b0b0b] px-3 py-2 font-mono text-[10px] leading-5 text-[#aaa]">{item.declaration}</code>
                          {item.documentation && <p className="mt-2 text-[11px] leading-5 text-[#777]">{item.documentation}</p>}
                        </div>
                      </article>
                    ))}
                  </div>
                </section>
              )) : (
                <div className="grid h-full place-items-center text-center">
                  <div><LibraryBig className="mx-auto text-[#4f4f4f]" size={22} /><p className="mt-3 text-xs text-[#777]">No standard interfaces match this search.</p></div>
                </div>
              )}
            </main>
          </div>
        )}
    </div>
  );
}

function anchor(name: string) {
  return name.replace(/[^a-z0-9]+/gi, "-");
}
