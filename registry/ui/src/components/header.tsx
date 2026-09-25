import { BookOpen, Boxes, Braces, Command, Download, Search } from "lucide-react";

type HeaderProps = {
  active: "libraries" | "standard" | "downloads" | "docs";
  onPalette: () => void;
  onLibraries: () => void;
  onStandard: () => void;
  onDocs: () => void;
  onDownloads: () => void;
};

export function Header({ active, onPalette, onLibraries, onStandard, onDocs, onDownloads }: HeaderProps) {
  const nav = (selected: boolean) => `flex h-7 items-center gap-1.5 rounded-lg px-2 text-[11px] transition-colors ${selected ? "bg-[#112628] text-[#60D5DF]" : "text-[#777] hover:bg-[#171717] hover:text-white"}`;
  return (
    <header className="flex h-12 shrink-0 items-center justify-between border-b border-[#242424] bg-[#0a0a0a]/95 px-3 sm:px-4">
      <a
        className="inline-flex items-center gap-2 text-[#f5f5f5] no-underline outline-none focus-visible:ring-2 focus-visible:ring-[#60D5DF]/70"
        href="/"
        aria-label="Foo Registry home"
      >
        <img className="size-6" src="/icon.svg" alt="" />
        <span className="text-[11px] font-medium text-[#5f5f5f]">REGISTRY</span>
      </a>

      <div className="flex items-center gap-2">
        <button className={nav(active === "libraries")} type="button" onClick={onLibraries} title="Browse libraries" aria-current={active === "libraries" ? "page" : undefined}>
          <Boxes size={13} /> <span className="hidden sm:inline">Libraries</span>
        </button>
        <button className={nav(active === "standard")} type="button" onClick={onStandard} title="Standard library reference" aria-current={active === "standard" ? "page" : undefined}>
          <Braces size={13} /> <span className="hidden sm:inline">Standard</span>
        </button>
        <button className={nav(active === "downloads")} type="button" onClick={onDownloads} title="Downloads" aria-current={active === "downloads" ? "page" : undefined}>
          <Download size={13} /> <span className="hidden sm:inline">Downloads</span>
        </button>
        <button className={nav(active === "docs")} type="button" onClick={onDocs} title="Documentation" aria-current={active === "docs" ? "page" : undefined}>
          <BookOpen size={13} /> <span className="hidden sm:inline">Docs</span>
        </button>
        <button
          className="flex h-7 items-center gap-2 rounded-lg border border-[#2a2a2a] bg-[#141414] px-2.5 text-[11px] text-[#929292] transition-colors hover:border-[#3a3a3a] hover:text-[#f5f5f5] sm:min-w-48"
          type="button"
          onClick={onPalette}
          title="Open command palette"
        >
          <Search size={14} />
          <span className="hidden sm:inline">Search or run a command</span>
          <span className="ml-auto hidden items-center gap-0.5 text-[10px] text-[#5f5f5f] sm:flex">
            <Command size={11} />K
          </span>
        </button>
      </div>
    </header>
  );
}
