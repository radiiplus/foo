import { Search as SearchIcon, X } from "lucide-react";
import type { RefObject } from "react";

type SearchProps = {
  value: string;
  inputRef: RefObject<HTMLInputElement | null>;
  onChange: (value: string) => void;
};

export function Search({ value, inputRef, onChange }: SearchProps) {
  return (
    <div className="relative">
      <SearchIcon className="pointer-events-none absolute top-1/2 left-3 -translate-y-1/2 text-[#686868]" size={15} />
      <input
        ref={inputRef}
        className="h-9 w-full rounded-lg border border-[#2a2a2a] bg-[#111] pr-9 pl-9 text-xs text-[#f5f5f5] outline-none placeholder:text-[#555] focus:border-[#32747A] focus:ring-3 focus:ring-[#60D5DF]/6"
        type="search"
        value={value}
        onChange={(event) => onChange(event.target.value)}
        placeholder="Search packages, tags, or categories..."
        aria-label="Search packages"
      />
      {value && (
        <button
          className="absolute top-1/2 right-3 grid size-6 -translate-y-1/2 place-items-center rounded-md text-[#5f5f5f] hover:bg-[#222] hover:text-[#f5f5f5]"
          type="button"
          onClick={() => onChange("")}
          title="Clear search"
        >
          <X size={13} />
        </button>
      )}
    </div>
  );
}
