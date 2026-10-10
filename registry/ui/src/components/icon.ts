import { createElement, type ReactNode } from "react";

export function Icon({ svg, children }: { svg?: string; children: ReactNode }) {
  const safe = typeof svg === "string" && svg.length <= 64 * 1024 && svg.startsWith('<svg xmlns="http://www.w3.org/2000/svg"');
  return safe ? createElement("img", {
    src: `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`,
    alt: "",
    loading: "lazy",
    decoding: "async",
  }) : children;
}
