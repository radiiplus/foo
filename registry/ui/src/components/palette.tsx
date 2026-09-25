import { BookOpen, Boxes, Braces, Download, GitFork, Search, Shapes, Terminal, X } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

type PaletteProps = {
  open: boolean;
  onClose: () => void;
  onSearch: () => void;
  onPackages: () => void;
  onCategories: () => void;
  onStandard: () => void;
  onDocs: () => void;
  onDownloads: () => void;
};

export function Palette({ open, onClose, onSearch, onPackages, onCategories, onStandard, onDocs, onDownloads }: PaletteProps) {
  const [query, setQuery] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const actions = useMemo(() => [
    { label: "Search packages", hint: "Focus discovery", icon: Search, run: onSearch },
    { label: "View all packages", hint: "Clear active filters", icon: Boxes, run: onPackages },
    { label: "Browse categories", hint: "Jump to taxonomy", icon: Shapes, run: onCategories },
    { label: "Standard library reference", hint: "Exact public names and signatures", icon: Braces, run: onStandard },
    { label: "Download FOO", hint: "Installers and portable archives", icon: Download, run: onDownloads },
    { label: "Read FOO documentation", hint: "Open the FOO Book", icon: BookOpen, run: onDocs },
    { label: "Open source repository", hint: "github.com/radiiplus/foo", icon: GitFork, run: () => window.open("https://github.com/radiiplus/foo", "_blank") },
  ], [onCategories, onDocs, onDownloads, onPackages, onSearch, onStandard]);
  const filtered = actions.filter((action) => action.label.toLowerCase().includes(query.toLowerCase()));

  useEffect(() => {
    if (open) {
      setQuery("");
      requestAnimationFrame(() => inputRef.current?.focus());
    }
  }, [open]);

  if (!open) return null;

  const run = (action: () => void) => {
    onClose();
    requestAnimationFrame(action);
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center bg-black/70 px-4 pt-[12vh] backdrop-blur-sm"
      role="presentation"
      onMouseDown={(event) => event.target === event.currentTarget && onClose()}
    >
      <section className="w-full max-w-xl overflow-hidden rounded-2xl border border-[#303030] bg-[#111] shadow-2xl shadow-black" role="dialog" aria-modal="true" aria-label="Command palette">
        <div className="flex h-13 items-center gap-3 border-b border-[#292929] px-4">
          <Terminal size={16} className="text-[#60D5DF]" />
          <input
            ref={inputRef}
            className="min-w-0 flex-1 bg-transparent text-sm text-[#f5f5f5] outline-none placeholder:text-[#555]"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Escape") onClose();
              if (event.key === "Enter" && filtered[0]) run(filtered[0].run);
            }}
            placeholder="Type a command..."
          />
          <button className="grid size-7 place-items-center rounded-lg text-[#666] hover:bg-[#222] hover:text-white" type="button" onClick={onClose} title="Close command palette">
            <X size={14} />
          </button>
        </div>
        <div className="p-2">
          <p className="px-3 py-2 text-[10px] font-semibold tracking-[0.14em] text-[#555] uppercase">Commands</p>
          {filtered.map((action) => {
            const Icon = action.icon;
            return (
              <button key={action.label} className="flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-left hover:bg-[#1b1b1b]" type="button" onClick={() => run(action.run)}>
                <span className="grid size-8 place-items-center rounded-lg border border-[#292929] bg-[#171717] text-[#888]">
                  <Icon size={14} />
                </span>
                <span>
                  <span className="block text-[13px] text-[#e8e8e8]">{action.label}</span>
                  <span className="block text-[11px] text-[#5f5f5f]">{action.hint}</span>
                </span>
              </button>
            );
          })}
        </div>
      </section>
    </div>
  );
}
