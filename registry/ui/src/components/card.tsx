import { ArrowUpRight, Braces, ShieldCheck } from "lucide-react";

import type { PackageSummary } from "../utils/registry";
import { displayPackageName } from "../utils/format";

type CardProps = {
  item: PackageSummary;
  onOpen: (name: string) => void;
  onTag: (tag: string) => void;
};

export function Card({ item, onOpen, onTag }: CardProps) {
  return (
    <article className="group flex min-h-0 flex-col overflow-hidden rounded-lg border border-[#242424] bg-[#111] p-3 transition-colors hover:border-[#343434] hover:bg-[#131313]">
      <div className="flex items-start justify-between gap-4">
        <button
          className="flex min-w-0 items-center gap-1 font-mono text-xs font-semibold text-[#f5f5f5] outline-none hover:text-[#60D5DF] focus-visible:text-[#60D5DF]"
          type="button"
          onClick={() => onOpen(item.name)}
        >
          {displayPackageName(item.name)}
          <ArrowUpRight size={13} className="text-[#5f5f5f] transition-colors group-hover:text-[#60D5DF]" />
        </button>
        <span className="font-mono text-[10px] text-[#60D5DF] max-[420px]:hidden">{item.version}</span>
      </div>

      <p className="mt-2 line-clamp-2 text-[11px] leading-4 text-[#929292] max-[420px]:hidden">{item.description}</p>

      <div className="mt-2 flex flex-wrap gap-1 max-[420px]:hidden">
        {(item.tags ?? []).slice(0, 3).map((tag) => (
          <button
            key={tag}
            className="rounded border border-[#292929] bg-[#171717] px-1.5 py-0.5 font-mono text-[8px] text-[#777] transition-colors hover:border-[#285A5E] hover:text-[#60D5DF]"
            type="button"
            onClick={() => onTag(tag)}
          >
            {tag}
          </button>
        ))}
      </div>

      <div className="mt-auto flex items-center justify-between border-t border-[#222] pt-2 text-[9px] text-[#666]">
        <span>{item.license}</span>
        <span className="flex items-center gap-2 max-[420px]:hidden">
          <span className="flex items-center gap-1"><Braces size={10} /> {(item.exports ?? []).length}</span>
          {item.compatible && (
            <span className="flex items-center gap-1.5 text-[#4EABB3]">
              <ShieldCheck size={11} />
              Compatible
            </span>
          )}
        </span>
      </div>
    </article>
  );
}
