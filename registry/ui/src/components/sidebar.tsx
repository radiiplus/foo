import { Activity, BookOpen, Boxes, Braces, Download, GitFork, LayoutGrid, Shapes, Tags } from "lucide-react";

type SidebarProps = {
  active: "discover" | "standard" | "detail" | "docs" | "downloads";
  online: boolean;
  onDiscover: () => void;
  onPackages: () => void;
  onCategories: () => void;
  onTags: () => void;
  onStandard: () => void;
  onDocs: () => void;
  onDownloads: () => void;
};

const base = "grid size-9 place-items-center rounded-lg transition-colors";

export function Sidebar({ active, online, onDiscover, onPackages, onCategories, onTags, onStandard, onDocs, onDownloads }: SidebarProps) {
  return (
    <aside className="hidden w-14 shrink-0 border-r border-[#242424] bg-[#0a0a0a] px-2 py-3 lg:flex lg:flex-col lg:items-center">
      <nav className="space-y-1" aria-label="Registry navigation">
        <button className={`${base} ${active === "discover" ? "bg-[#1b1b1b] text-[#f5f5f5]" : "text-[#707070] hover:bg-[#141414] hover:text-[#f5f5f5]"}`} type="button" onClick={onDiscover} title="Overview">
          <LayoutGrid size={15} strokeWidth={1.8} />
        </button>
        <button className={`${base} text-[#707070] hover:bg-[#141414] hover:text-[#f5f5f5]`} type="button" onClick={onPackages} title="Packages">
          <Boxes size={15} strokeWidth={1.8} />
        </button>
        <button className={`${base} text-[#707070] hover:bg-[#141414] hover:text-[#f5f5f5]`} type="button" onClick={onCategories} title="Categories">
          <Shapes size={15} strokeWidth={1.8} />
        </button>
        <button className={`${base} text-[#707070] hover:bg-[#141414] hover:text-[#f5f5f5]`} type="button" onClick={onTags} title="Tags">
          <Tags size={15} strokeWidth={1.8} />
        </button>
        <button className={`${base} ${active === "standard" ? "bg-[#1b1b1b] text-[#60D5DF]" : "text-[#707070] hover:bg-[#141414] hover:text-[#f5f5f5]"}`} type="button" onClick={onStandard} title="Standard library">
          <Braces size={15} strokeWidth={1.8} />
        </button>
      </nav>

      <div className="mt-3 space-y-1 border-t border-[#242424] pt-3">
        <button className={`${base} ${active === "downloads" ? "bg-[#1b1b1b] text-[#60D5DF]" : "text-[#707070] hover:bg-[#141414] hover:text-[#f5f5f5]"}`} type="button" onClick={onDownloads} title="Downloads">
          <Download size={15} strokeWidth={1.8} />
        </button>
        <a className={`${base} text-[#707070] no-underline hover:bg-[#141414] hover:text-[#f5f5f5]`} href="https://github.com/radiiplus/foo" target="_blank" rel="noreferrer" title="Source">
          <GitFork size={15} strokeWidth={1.8} />
        </a>
        <button className={`${base} ${active === "docs" ? "bg-[#1b1b1b] text-[#60D5DF]" : "text-[#707070] hover:bg-[#141414] hover:text-[#f5f5f5]"}`} type="button" onClick={onDocs} title="Documentation">
          <BookOpen size={15} strokeWidth={1.8} />
        </button>
      </div>

      <div className={`mt-auto grid size-9 place-items-center rounded-lg ${online ? "text-[#60D5DF]" : "text-[#ff625f]"}`} title={online ? "Registry online" : "Registry offline"}>
        <Activity size={14} />
      </div>
    </aside>
  );
}
