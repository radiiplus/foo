import { BookOpen, Boxes, Braces, Download, Search } from "lucide-react";

type HeaderProps = {
  active: "libraries" | "standard" | "downloads" | "docs";
  onPalette: () => void;
  onLibraries: () => void;
  onStandard: () => void;
  onDocs: () => void;
  onDownloads: () => void;
};

export function Header({ active, onPalette, onLibraries, onStandard, onDocs, onDownloads }: HeaderProps) {
  return (
    <header className="registry-site-header">
      <a className="registry-brand" href="/" aria-label="FOO home">
        <img src="/icon.svg" alt="" />
        <strong>FOO</strong><i /><span>REGISTRY</span>
      </a>
      <nav aria-label="Primary navigation">
        <button className={active === "libraries" ? "active" : ""} type="button" onClick={onLibraries} title="Libraries" aria-current={active === "libraries" ? "page" : undefined}><Boxes size={16} /><span>Libraries</span></button>
        <button className={active === "standard" ? "active" : ""} type="button" onClick={onStandard} title="Standard library" aria-current={active === "standard" ? "page" : undefined}><Braces size={16} /><span>Standard</span></button>
        <button className={active === "docs" ? "active" : ""} type="button" onClick={onDocs} title="Documentation" aria-current={active === "docs" ? "page" : undefined}><BookOpen size={16} /><span>Docs</span></button>
        <button className={active === "downloads" ? "active" : ""} type="button" onClick={onDownloads} title="Downloads" aria-current={active === "downloads" ? "page" : undefined}><Download size={16} /><span>Downloads</span></button>
        <button className="registry-global-search" type="button" onClick={onPalette} title="Search and commands" aria-label="Search and commands"><Search size={17} /></button>
      </nav>
    </header>
  );
}
