import { Search as SearchIcon, X } from "lucide-react";
import type { RefObject } from "react";

type SearchProps = {
  value: string;
  inputRef: RefObject<HTMLInputElement | null>;
  onChange: (value: string) => void;
};

export function Search({ value, inputRef, onChange }: SearchProps) {
  return (
    <div className="registry-search">
      <SearchIcon size={17} aria-hidden="true" />
      <input
        ref={inputRef}
        type="search"
        value={value}
        onChange={(event) => onChange(event.target.value)}
        placeholder="Search libraries, symbols, tags"
        aria-label="Search libraries"
      />
      {value && (
        <button
          type="button"
          onClick={() => onChange("")}
          title="Clear search"
          aria-label="Clear search"
        >
          <X size={13} />
        </button>
      )}
    </div>
  );
}
