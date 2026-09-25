import {
  ArrowDownWideNarrow,
  FileJson,
  GitBranch,
  LoaderCircle,
  MoreHorizontal,
  PackageSearch,
  Pin,
  RotateCw,
  Shapes,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState, type RefObject } from "react";

import { Card } from "../components/card";
import { Categories } from "../components/categories";
import { Search } from "../components/search";
import {
  packages as loadPackages,
  type Category,
  type PackageSummary,
  type Query,
  type Tag,
} from "../utils/registry";

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

const pageSize = 12;

export default function Discover({ action, inputRef, onOpen }: DiscoverProps) {
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState("");
  const [tag, setTag] = useState("");
  const [kind, setKind] = useState<"" | "standard" | "package">("");
  const [sort, setSort] = useState<Query["sort"]>("recent");
  const [items, setItems] = useState<PackageSummary[]>([]);
  const [total, setTotal] = useState(0);
  const [categories, setCategories] = useState<Category[]>([]);
  const [quickTags, setQuickTags] = useState<Tag[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState("");
  const [refresh, setRefresh] = useState(0);
  const [categoryOpen, setCategoryOpen] = useState(false);
  const packagesRef = useRef<HTMLDivElement>(null);
  const sentinelRef = useRef<HTMLDivElement>(null);
  const moreControllerRef = useRef<AbortController | undefined>(undefined);

  useEffect(() => {
    moreControllerRef.current?.abort();
    const controller = new AbortController();
    const timer = window.setTimeout(() => {
      setLoading(true);
      setLoadingMore(false);
      setError("");
      setItems([]);
      setTotal(0);
      packagesRef.current?.scrollTo({ top: 0 });
      void loadPackages({ query, category, tag, kind: kind || undefined, sort, offset: 0, limit: pageSize }, controller.signal)
        .then((result) => {
          setItems(result.packages);
          setTotal(result.total);
          setCategories(result.facets.categories);
          setQuickTags(result.facets.tags.slice(0, 5));
        })
        .catch((reason: unknown) => {
          if (!(reason instanceof DOMException && reason.name === "AbortError")) setError("Registry index unavailable");
        })
        .finally(() => setLoading(false));
    }, query ? 140 : 0);

    return () => {
      window.clearTimeout(timer);
      controller.abort();
    };
  }, [query, category, tag, kind, sort, refresh]);

  const loadMore = useCallback(() => {
    if (loading || loadingMore || items.length >= total) return;
    const controller = new AbortController();
    moreControllerRef.current = controller;
    setLoadingMore(true);
    void loadPackages({ query, category, tag, kind: kind || undefined, sort, offset: items.length, limit: pageSize }, controller.signal)
      .then((result) => {
        setItems((current) => {
          const existing = new Set(current.map((item) => item.name));
          return [...current, ...result.packages.filter((item) => !existing.has(item.name))];
        });
        setTotal(result.total);
      })
      .catch((reason: unknown) => {
        if (!(reason instanceof DOMException && reason.name === "AbortError")) setError("More packages unavailable");
      })
      .finally(() => {
        if (moreControllerRef.current === controller) setLoadingMore(false);
      });
  }, [category, items, kind, loading, loadingMore, query, sort, tag, total]);

  useEffect(() => {
    const sentinel = sentinelRef.current;
    const root = packagesRef.current;
    if (!sentinel || !root || loading || items.length >= total) return;
    const observer = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) loadMore();
    }, { root, rootMargin: "120px 0px" });
    observer.observe(sentinel);
    return () => observer.disconnect();
  }, [items.length, loadMore, loading, total]);

  useEffect(() => () => moreControllerRef.current?.abort(), []);

  useEffect(() => {
    if (action.type === "focus") inputRef.current?.focus();
    if (action.type === "reset") {
      setQuery("");
      setCategory("");
      setTag("");
      setKind("");
      setCategoryOpen(false);
      window.scrollTo({ top: 0, behavior: "smooth" });
    }
    if (action.type === "categories") setCategoryOpen(true);
    if (action.type === "tags") inputRef.current?.focus();
    if (action.type === "tag" && action.value) setTag(action.value);
  }, [action, inputRef]);

  const filters = useMemo(() => [category, tag].filter(Boolean), [category, tag]);

  return (
    <div className="mx-auto flex h-full w-full max-w-[1400px] flex-col overflow-hidden px-3 py-2 sm:px-4">
      <header className="mb-2 flex shrink-0 items-center justify-between gap-3 border-b border-[#242424] pb-2">
        <div className="flex min-w-0 items-baseline gap-3">
          <div>
            <p className="font-mono text-[8px] tracking-[0.16em] text-[#60D5DF] uppercase">Discover / Index 01</p>
            <h1 className="mt-0.5 text-sm font-semibold text-[#f5f5f5]">Libraries</h1>
          </div>
          <p className="truncate text-[10px] text-[#6f6f6f] max-sm:hidden">Standard modules and published Foo packages.</p>
        </div>
        <div className="flex items-center gap-1.5 font-mono text-[9px] text-[#5f5f5f]">
          <span className="size-1.5 rounded-full bg-[#60D5DF]" />
          {total} indexed
        </div>
      </header>

      <div className="grid min-h-0 flex-1 gap-3 xl:grid-cols-[minmax(0,1fr)_40px]">
        <div className="flex min-h-0 min-w-0 flex-col">
          <div className="grid shrink-0 gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
            <Search value={query} inputRef={inputRef} onChange={setQuery} />
            <div className="flex rounded-md border border-[#292929] bg-[#0e0e0e] p-0.5" role="group" aria-label="Library kind">
              {([{"label": "All", "value": ""}, {"label": "Standard", "value": "standard"}, {"label": "Packages", "value": "package"}] as const).map((option) => (
                <button key={option.label} className={`h-8 rounded px-2 text-[9px] ${kind === option.value ? "bg-[#112628] text-[#60D5DF]" : "text-[#666] hover:text-[#bbb]"}`} type="button" onClick={() => setKind(option.value)}>{option.label}</button>
              ))}
            </div>
          </div>

          <div className="mt-1.5 flex min-h-7 shrink-0 items-center justify-between gap-3">
            <div className="flex min-w-0 items-center gap-1.5 text-[10px] text-[#6f6f6f]">
              <PackageSearch size={12} />
              <span>{loading ? "Reading index..." : `${total} result${total === 1 ? "" : "s"}`}</span>
              <span className="mx-1 h-3 w-px bg-[#292929]" />
              <span className="text-[8px] font-semibold tracking-[0.1em] text-[#555] uppercase max-sm:hidden">Tags</span>
              {quickTags.map((item) => (
                <button key={item.name} className={`rounded border px-1.5 py-0.5 font-mono text-[8px] transition-colors max-[520px]:hidden ${tag === item.name ? "border-[#32747a] bg-[#112628] text-[#60D5DF]" : "border-[#272727] bg-[#111] text-[#6f6f6f] hover:text-[#60D5DF]"}`} type="button" onClick={() => setTag(tag === item.name ? "" : item.name)} title={`${item.count} package${item.count === 1 ? "" : "s"}`}>{item.name}</button>
              ))}
              {filters.map((filter) => (
                <button key={filter} className="rounded-lg bg-[#112628] px-2 py-1 font-mono text-[10px] text-[#60D5DF]" type="button" onClick={() => filter === category ? setCategory("") : setTag("")}>
                  {filter} &times;
                </button>
              ))}
            </div>
            <div className="flex shrink-0 items-center gap-1.5">
              <Categories items={categories} value={category} open={categoryOpen} onOpenChange={setCategoryOpen} onChange={setCategory} />
              <label className="flex shrink-0 items-center gap-1.5 text-[10px] text-[#666]">
                <ArrowDownWideNarrow size={12} />
                <span className="sr-only">Sort packages</span>
                <select className="rounded-md border border-[#292929] bg-[#111] px-2 py-1 text-[10px] text-[#929292] outline-none focus:border-[#32747a]" value={sort} onChange={(event) => setSort(event.target.value as Query["sort"])}>
                  <option value="recent">Recently updated</option>
                  <option value="category">Category</option>
                  <option value="name">Name</option>
                </select>
              </label>
            </div>
          </div>

          {error ? (
            <div className="mt-4 flex min-h-48 flex-col items-center justify-center rounded-xl border border-[#302323] bg-[#151111] text-center">
              <p className="text-sm text-[#d58d8b]">{error}</p>
              <button className="mt-3 flex items-center gap-2 rounded-lg border border-[#353535] px-3 py-2 text-xs text-[#aaa] hover:text-white" type="button" onClick={() => setRefresh((value) => value + 1)}>
                <RotateCw size={13} /> Retry
              </button>
            </div>
          ) : loading ? (
            <div className="mt-2 grid min-h-0 flex-1 grid-cols-1 grid-rows-3 gap-2 min-[440px]:grid-cols-2 xl:h-[316px] xl:flex-none xl:grid-cols-3 xl:grid-rows-2 2xl:grid-cols-4">
              {[0, 1, 2, 3, 4, 5].map((item) => <div key={item} className="min-h-0 animate-pulse rounded-lg border border-[#222] bg-[#101010]" />)}
            </div>
          ) : items.length ? (
            <div ref={packagesRef} className="mt-2 min-h-0 flex-1 overflow-y-auto overscroll-contain pr-1">
              <div className="grid grid-cols-1 auto-rows-[154px] gap-2 min-[440px]:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4 max-[420px]:auto-rows-[96px]">
                {items.map((item) => <Card key={item.name} item={item} onOpen={onOpen} onTag={setTag} />)}
              </div>
              {items.length < total && (
                <div ref={sentinelRef} className="grid h-8 place-items-center text-[#32747a]" aria-label="Loading more packages">
                  {loadingMore && <LoaderCircle className="animate-spin" size={13} />}
                </div>
              )}
            </div>
          ) : (
            <div className="mt-4 grid min-h-48 place-items-center rounded-xl border border-dashed border-[#292929] text-center">
              <div>
                <PackageSearch className="mx-auto mb-3 text-[#4f4f4f]" size={21} />
                <p className="text-sm text-[#929292]">No packages match this index query.</p>
                <button className="mt-2 text-xs text-[#60D5DF]" type="button" onClick={() => { setQuery(""); setCategory(""); setTag(""); }}>Clear filters</button>
              </div>
            </div>
          )}
        </div>

        <aside id="categories" className="hidden self-start border-l border-[#242424] pl-1.5 xl:block">
          <div className="space-y-0.5">
            <button className={`grid size-8 place-items-center rounded-md ${category === "" ? "bg-[#112628] text-[#60D5DF]" : "text-[#666] hover:bg-[#151515] hover:text-white"}`} type="button" onClick={() => setCategory("")} title="All categories">
              <PackageSearch size={13} />
            </button>
            {categories.slice(0, 4).map((item) => (
              <button
                key={item.name}
                className={`relative grid size-8 place-items-center rounded-md transition-colors ${category === item.name ? "bg-[#112628] text-[#60D5DF]" : "text-[#666] hover:bg-[#151515] hover:text-[#f5f5f5]"}`}
                type="button"
                onClick={() => setCategory(category === item.name ? "" : item.name)}
                title={`${item.name} / ${item.count}`}
              >
                <Shapes size={14} />
                <span className="absolute -top-0.5 -right-0.5 font-mono text-[7px] text-[#555]">{item.count}</span>
              </button>
            ))}
            <button className="grid size-8 place-items-center rounded-md text-[#666] hover:bg-[#151515] hover:text-white" type="button" onClick={() => setCategoryOpen(true)} title="Browse all categories">
              <MoreHorizontal size={13} />
            </button>
          </div>

          <div className="mt-2 space-y-0.5 border-t border-[#242424] pt-2 text-[#555]">
            <span className="grid size-8 place-items-center rounded-md" title="Format: index/v1"><FileJson size={13} /></span>
            <span className="grid size-8 place-items-center rounded-md" title="Resolution: exact"><Pin size={13} /></span>
            <span className="grid size-8 place-items-center rounded-md" title="Transport: git"><GitBranch size={13} /></span>
          </div>
        </aside>
      </div>
    </div>
  );
}
