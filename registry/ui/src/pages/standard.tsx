import { ArrowUpRight, ChevronLeft, ChevronRight, FileJson, LibraryBig, Search } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import { standardIndex, standards, type PublicApiItem, type StandardPackage } from "../utils/registry";
import { displayPackageName } from "../utils/format";
import { PackageArtwork } from "../components/package-artwork";

type StandardProps = { onOpen: (name: string, symbolId?: string) => void };
type SymbolMatch = { id: string; entry: PublicApiItem };
type Match = { packageItem: StandardPackage; items: SymbolMatch[] };
const PAGE_SIZE = 20;

export default function Standard({ onOpen }: StandardProps) {
  const initial = useMemo(readStandardState, []);
  const [packages, setPackages] = useState<StandardPackage[]>([]);
  const [query, setQuery] = useState(initial.query);
  const [page, setPage] = useState(initial.page);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const resultsRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const controller = new AbortController();
    document.title = "Standard Library - FOO";
    void standards(controller.signal)
      .then(setPackages)
      .catch((reason: unknown) => {
        if (!(reason instanceof DOMException && reason.name === "AbortError")) setError("Standard library index unavailable");
      })
      .finally(() => setLoading(false));
    return () => { controller.abort(); document.title = "FOO Registry"; };
  }, []);

  const matches = useMemo<Match[]>(() => {
    const needle = query.trim().toLowerCase();
    return packages.flatMap((packageItem) => {
      const all = packageItem.api.modules.flatMap((module) => module.items.map((entry, index) => ({
        id: `${module.path}:${entry.kind}:${entry.name}:${index}`,
        entry,
      })));
      if (!needle || `${packageItem.name} ${packageItem.description}`.toLowerCase().includes(needle)) return [{ packageItem, items: all }];
      const items = all.filter(({ entry }) => `${entry.kind} ${entry.name} ${entry.declaration} ${entry.documentation}`.toLowerCase().includes(needle));
      return items.length ? [{ packageItem, items }] : [];
    });
  }, [packages, query]);

  const pageCount = Math.max(1, Math.ceil(matches.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount - 1);
  const pageStart = currentPage * PAGE_SIZE;
  const visibleMatches = matches.slice(pageStart, pageStart + PAGE_SIZE);
  const itemCount = packages.reduce((count, packageItem) => count + packageItem.api.modules.reduce((sum, module) => sum + module.items.length, 0), 0);

  useEffect(() => { if (resultsRef.current) resultsRef.current.scrollTop = 0; }, [currentPage, query]);
  useEffect(() => {
    if (loading) return;
    const url = new URL(window.location.href);
    if (query) url.searchParams.set("q", query);
    else url.searchParams.delete("q");
    if (currentPage) url.searchParams.set("page", String(currentPage + 1));
    else url.searchParams.delete("page");
    window.history.replaceState(window.history.state ?? {}, "", `${url.pathname}${url.search}`);
  }, [query, currentPage, loading]);

  return <div className="registry-standard">
    <div className="registry-standard-toolbar">
      <header className="registry-standard-head"><h1>Standard library</h1><span>{loading ? "Loading" : `${matches.length} modules / ${itemCount} symbols`}</span></header>
      <label className="registry-standard-search"><Search size={16} /><span className="sr-only">Search standard modules and symbols</span><input type="search" value={query} onChange={(event) => { setQuery(event.target.value); setPage(0); }} placeholder="Find modules, functions, types" /></label>
      <a className="registry-standard-index" href={standardIndex()} target="_blank" rel="noreferrer" title="Machine-readable standard library index" aria-label="Machine-readable standard library index"><FileJson size={16} /></a>
    </div>
    <div ref={resultsRef} className="registry-standard-results">
      {loading ? <div className="registry-loading">Reading public interfaces...</div>
        : error ? <div className="registry-empty"><LibraryBig size={22} /><p>{error}</p></div>
        : matches.length ? <div className="registry-standard-masonry">{visibleMatches.map(({ packageItem, items }) => <article className="registry-result-card registry-standard-card standard" key={packageItem.name}>
            <button className="registry-result-primary" type="button" onClick={() => onOpen(packageItem.name)}>
              <span className="registry-card-top"><span className="registry-result-icon" aria-hidden="true"><PackageArtwork name={packageItem.name} kind="standard" /></span><ArrowUpRight size={16} aria-hidden="true" /></span>
              <span className="registry-result-kind">Standard library</span>
              <strong className="registry-result-name">{displayPackageName(packageItem.name)}</strong>
              <span className="registry-result-description">{packageItem.description}</span>
              <span className="registry-result-meta"><span>Public interface</span><span>{items.length} {items.length === 1 ? "symbol" : "symbols"}</span></span>
            </button>
            {query && items.length > 0 && <div className="registry-module-symbols">{items.slice(0, 5).map(({ id, entry }) => <button type="button" key={id} onClick={() => onOpen(packageItem.name, id)}>{entry.name}</button>)}{items.length > 5 && <span>+{items.length - 5} more</span>}</div>}
          </article>)}</div>
        : <div className="registry-empty"><LibraryBig size={22} /><p>No standard modules match this search.</p></div>}
    </div>
    {!loading && !error && pageCount > 1 && <nav className="registry-pagination" aria-label="Standard library pages"><span>{pageStart + 1}-{Math.min(pageStart + PAGE_SIZE, matches.length)} of {matches.length}</span><div><button type="button" title="Previous page" aria-label="Previous page" disabled={currentPage === 0} onClick={() => setPage(currentPage - 1)}><ChevronLeft size={16} /></button><span>Page {currentPage + 1} of {pageCount}</span><button type="button" title="Next page" aria-label="Next page" disabled={currentPage === pageCount - 1} onClick={() => setPage(currentPage + 1)}><ChevronRight size={16} /></button></div></nav>}
  </div>;
}

function readStandardState() {
  const params = new URLSearchParams(window.location.search);
  const page = Number(params.get("page"));
  return { query: params.get("q") ?? "", page: Number.isSafeInteger(page) && page > 0 ? page - 1 : 0 };
}
