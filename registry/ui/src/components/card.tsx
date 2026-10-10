import { ArrowUpRight } from "lucide-react";

import type { PackageSummary } from "../utils/registry";
import { displayPackageName } from "../utils/format";
import { PackageArtwork } from "./package-artwork";

type CardProps = {
  item: PackageSummary;
  index: number;
  onOpen: (name: string) => void;
};

export function Card({ item, index, onOpen }: CardProps) {
  return (
    <article className={`registry-result-card rounded-lg transition-transform duration-300 ${item.kind === "standard" ? "standard" : "community"}`} style={{ animationDelay: `${Math.min(index, 8) * 20}ms` }}>
      <button className="registry-result-primary" type="button" onClick={() => onOpen(item.name)}>
        <span className="registry-card-top"><span className={`registry-result-icon${item.icon ? " custom" : ""}`} aria-hidden="true"><PackageArtwork name={item.name} kind={item.kind} icon={item.icon} /></span><ArrowUpRight size={16} aria-hidden="true" /></span>
        <span className="registry-result-kind">{item.kind === "standard" ? "Standard library" : "Community package"}</span>
        <strong className="registry-result-name">{displayPackageName(item.name)}</strong>
        <span className="registry-result-description">{item.description}</span>
        <span className="registry-result-meta"><span>{item.category}</span><code>{item.version}</code></span>
      </button>
    </article>
  );
}
