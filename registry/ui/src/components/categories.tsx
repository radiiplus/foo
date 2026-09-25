import { Check, ChevronDown, Search, Shapes } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import type { Category } from "../utils/registry";

type CategoriesProps = {
  items: Category[];
  value: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onChange: (value: string) => void;
};

export function Categories({ items, value, open, onOpenChange, onChange }: CategoriesProps) {
  const [query, setQuery] = useState("");
  const rootRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const filtered = useMemo(() => items.filter((item) => item.name.toLowerCase().includes(query.toLowerCase())), [items, query]);

  useEffect(() => {
    if (!open) return;
    setQuery("");
    requestAnimationFrame(() => inputRef.current?.focus());
    const close = (event: MouseEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) onOpenChange(false);
    };
    const escape = (event: KeyboardEvent) => {
      if (event.key === "Escape") onOpenChange(false);
    };
    document.addEventListener("mousedown", close);
    document.addEventListener("keydown", escape);
    return () => {
      document.removeEventListener("mousedown", close);
      document.removeEventListener("keydown", escape);
    };
  }, [onOpenChange, open]);

  const select = (name: string) => {
    onChange(name);
    onOpenChange(false);
  };

  return (
    <div ref={rootRef} className="relative">
      <button
        className={`flex h-7 items-center gap-1.5 rounded-md border px-2 text-[10px] ${value ? "border-[#32747A] bg-[#112628] text-[#60D5DF]" : "border-[#292929] bg-[#111] text-[#777] hover:text-white"}`}
        type="button"
        onClick={() => onOpenChange(!open)}
        aria-expanded={open}
        aria-haspopup="listbox"
      >
        <Shapes size={12} />
        <span className="max-w-24 truncate">{value || "Categories"}</span>
        <ChevronDown size={11} />
      </button>

      {open && (
        <div className="absolute top-full right-0 z-30 mt-1.5 w-64 max-w-[calc(100vw-2rem)] overflow-hidden rounded-lg border border-[#303030] bg-[#111] shadow-2xl shadow-black" role="listbox" aria-label="Package categories">
          <label className="flex h-9 items-center gap-2 border-b border-[#292929] px-3 text-[#666]">
            <Search size={12} />
            <input ref={inputRef} className="min-w-0 flex-1 bg-transparent text-[11px] text-white outline-none placeholder:text-[#555]" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Find a category" />
          </label>
          <div className="max-h-52 overflow-y-auto p-1.5">
            <button className="flex w-full items-center justify-between rounded-md px-2 py-1.5 text-left text-[11px] text-[#aaa] hover:bg-[#1b1b1b]" type="button" onClick={() => select("")}>
              All categories
              {!value && <Check size={12} className="text-[#60D5DF]" />}
            </button>
            {filtered.map((item) => (
              <button key={item.name} className="flex w-full items-center justify-between rounded-md px-2 py-1.5 text-left text-[11px] text-[#aaa] hover:bg-[#1b1b1b]" type="button" onClick={() => select(item.name)} role="option" aria-selected={value === item.name}>
                <span className="truncate">{item.name}</span>
                <span className="ml-3 flex items-center gap-2 font-mono text-[9px] text-[#555]">
                  {item.count}
                  {value === item.name && <Check size={12} className="text-[#60D5DF]" />}
                </span>
              </button>
            ))}
            {!filtered.length && <p className="px-2 py-4 text-center text-[10px] text-[#555]">No matching categories</p>}
          </div>
        </div>
      )}
    </div>
  );
}
