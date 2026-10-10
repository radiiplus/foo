import { ArrowDownWideNarrow, Boxes, Braces, ChevronLeft, ChevronRight, LayoutGrid, PackageSearch, RotateCw, X } from "lucide-react";
import { useEffect, useMemo, useRef, useState, type RefObject } from "react";

import { Card } from "../components/card";
import { Categories } from "../components/categories";
import { Search } from "../components/search";
import { packages as loadPackages, type Category, type PackageSummary, type Query } from "../utils/registry";

export type Action = {
  id: number;
  type: "focus" | "reset" | "categories" | "tags" | "tag";
  value?: string;
};

type DiscoverProps = {
  action: Action;
  inputRef: RefObject<HTMLInputElement | null>;
  onOpen: (name: string) => void;
};

const pageSize = 20;

export default function Discover({ action, inputRef, onOpen }: DiscoverProps) {
  const initial = useMemo(readDiscoveryState, []);
  const [query, setQuery] = useState(initial.query);
  const [category, setCategory] = useState(initial.category);
  const [tag, setTag] = useState(initial.tag);
  const [kind, setKind] = useState<"" | "standard" | "package">(initial.kind);
  const [sort, setSort] = useState<Query["sort"]>(initial.sort);
  const [items, setItems] = useState<PackageSummary[]>([]);
  const [total, setTotal] = useState(0);
  const [categories, setCategories] = useState<Category[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [refresh, setRefresh] = useState(0);
  const [categoryOpen, setCategoryOpen] = useState(false);
  const resultsRef = useRef<HTMLDivElement>(null);
  const filterKey = JSON.stringify([query, category, tag, kind, sort]);
  const [pagination, setPagination] = useState(() => ({ key: filterKey, page: initial.page }));
  const page = pagination.key === filterKey ? pagination.page : 0;
  const pageCount = Math.max(1, Math.ceil(total / pageSize));

  useEffect(() => {
    const url = new URL(window.location.href);
    for (const [key, value] of [["q", query], ["category", category], ["tag", tag], ["kind", kind], ["sort", sort === "recent" ? "" : sort ?? ""], ["page", page ? String(page + 1) : ""]]) {
      if (value) url.searchParams.set(key, value);
      else url.searchParams.delete(key);
    }
    window.history.replaceState(window.history.state ?? {}, "", `${url.pathname}${url.search}`);
  }, [query, category, tag, kind, sort, page]);

  useEffect(() => {
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      setLoading(true);
      setError("");
      setItems([]);
      setTotal(0);
      if (resultsRef.current) resultsRef.current.scrollTop = 0;
      void loadPackages({ query, category, tag, kind: kind || undefined, sort, offset: page * pageSize, limit: pageSize }, controller.signal)
        .then((result) => {
          if (result.total && page * pageSize >= result.total) {
            setPagination({ key: filterKey, page: Math.ceil(result.total / pageSize) - 1 });
            return;
          }
          setItems(result.packages);
          setTotal(result.total);
          setCategories(result.facets.categories);
        })
        .catch((reason: unknown) => {
          if (!(reason instanceof DOMException && reason.name === "AbortError")) setError("Registry index unavailable");
        })
        .finally(() => setLoading(false));
    }, query ? 140 : 0);
    return () => { window.clearTimeout(timer); controller.abort(); };
  }, [query, category, tag, kind, sort, page, refresh, filterKey]);

  useEffect(() => {
    if (action.type === "focus" || action.type === "tags") inputRef.current?.focus();
    if (action.type === "reset" && action.id !== 0) {
      setQuery("");
      setCategory("");
      setTag("");
      setKind("");
      setCategoryOpen(false);
      if (resultsRef.current) resultsRef.current.scrollTop = 0;
    }
    if (action.type === "categories") setCategoryOpen(true);
    if (action.type === "tag" && action.value) setTag(action.value);
  }, [action, inputRef]);

  const clearFilters = () => { setQuery(""); setCategory(""); setTag(""); setKind(""); };

  return (
    <div className="registry-discover">
      <div className="registry-discover-toolbar">
        <header className="registry-discover-head"><h1>Libraries</h1></header>
        <div className="registry-discover-controls">
          <Search value={query} inputRef={inputRef} onChange={setQuery} />
          <div className="registry-kind-tabs" role="group" aria-label="Library kind">
            {([{ label: "All", value: "", icon: LayoutGrid }, { label: "Standard", value: "standard", icon: Braces }, { label: "Packages", value: "package", icon: Boxes }] as const).map((option) =>
              <button key={option.label} type="button" className={kind === option.value ? "active" : ""} aria-label={option.label} title={option.label} aria-pressed={kind === option.value} onClick={() => setKind(option.value)}><option.icon size={15} /></button>)}
          </div>
          <Categories items={categories} value={category} open={categoryOpen} onOpenChange={setCategoryOpen} onChange={setCategory} />
          <label className="registry-sort" title="Sort libraries"><ArrowDownWideNarrow size={15} /><span className="sr-only">Sort libraries</span><select aria-label="Sort libraries" value={sort} onChange={(event) => setSort(event.target.value as Query["sort"])}><option value="recent">Recent</option><option value="category">Category</option><option value="name">Name</option></select></label>
        </div>
      </div>

      <div className="registry-results-meta"><span className="registry-result-count"><PackageSearch size={13} />{loading ? "Loading" : `${total} ${total === 1 ? "result" : "results"}`}</span>
      {(category || tag) && <div className="registry-active-filters">
        {category && <button type="button" onClick={() => setCategory("")}>{category}<X size={12} /></button>}
        {tag && <button type="button" onClick={() => setTag("")}>{tag}<X size={12} /></button>}
      </div>}</div>

      <div ref={resultsRef} className="registry-results" aria-live="polite">
        {error ? <div className="registry-results-message"><p>{error}</p><button type="button" onClick={() => setRefresh((value) => value + 1)}><RotateCw size={14} /> Retry</button></div>
          : loading ? <div className="registry-results-loading">{Array.from({ length: 7 }, (_, index) => <div key={index} />)}</div>
          : items.length ? <div className="registry-masonry columns-1 md:columns-2 xl:columns-4 2xl:columns-5">{items.map((item, index) => <Card key={item.name} item={item} index={index} onOpen={onOpen} />)}</div>
          : <div className="registry-results-message"><PackageSearch size={22} /><p>No libraries match this search.</p><button type="button" onClick={clearFilters}>Clear filters</button></div>}
      </div>

      {!loading && !error && pageCount > 1 && <nav className="registry-pagination" aria-label="Library pages">
        <span>{page * pageSize + 1}-{Math.min((page + 1) * pageSize, total)} of {total}</span>
        <div><button type="button" title="Previous page" aria-label="Previous page" disabled={page === 0} onClick={() => setPagination({ key: filterKey, page: page - 1 })}><ChevronLeft size={16} /></button><span>Page {page + 1} of {pageCount}</span><button type="button" title="Next page" aria-label="Next page" disabled={page === pageCount - 1} onClick={() => setPagination({ key: filterKey, page: page + 1 })}><ChevronRight size={16} /></button></div>
      </nav>}
    </div>
  );
}

function readDiscoveryState(): { query: string; category: string; tag: string; kind: "" | "standard" | "package"; sort: NonNullable<Query["sort"]>; page: number } {
  const params = new URLSearchParams(window.location.search);
  const kind = params.get("kind");
  const sort = params.get("sort");
  const page = Number(params.get("page"));
  return {
    query: params.get("q") ?? "",
    category: params.get("category") ?? "",
    tag: params.get("tag") ?? "",
    kind: kind === "standard" || kind === "package" ? kind : "",
    sort: sort === "name" || sort === "category" ? sort : "recent",
    page: Number.isSafeInteger(page) && page > 0 ? page - 1 : 0,
  };
}
