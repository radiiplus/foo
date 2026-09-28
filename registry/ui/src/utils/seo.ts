const domain = "https://fooregistry.web.app";

export type Input = {
  title: string;
  description: string;
  path?: string;
  noindex?: boolean;
};

function meta(selector: string, attribute: "name" | "property", key: string) {
  let element = document.head.querySelector<HTMLMetaElement>(selector);
  if (!element) {
    element = document.createElement("meta");
    element.setAttribute(attribute, key);
    document.head.append(element);
  }
  return element;
}

export function seo({ title, description, path, noindex = false }: Input) {
  const configured = import.meta.env.VITE_SITE_URL?.replace(/\/$/, "");
  const origin = configured || domain;
  const pathname = path ?? window.location.pathname;
  const url = `${origin}${pathname === "/" ? "/" : pathname}`;

  document.title = title;
  meta('meta[name="description"]', "name", "description").content = description;
  meta('meta[name="robots"]', "name", "robots").content = noindex
    ? "noindex, follow"
    : "index, follow, max-image-preview:large";
  meta('meta[property="og:title"]', "property", "og:title").content = title;
  meta('meta[property="og:description"]', "property", "og:description").content = description;
  meta('meta[property="og:url"]', "property", "og:url").content = url;
  meta('meta[name="twitter:title"]', "name", "twitter:title").content = title;
  meta('meta[name="twitter:description"]', "name", "twitter:description").content = description;

  let canonical = document.head.querySelector<HTMLLinkElement>('link[rel="canonical"]');
  if (!canonical) {
    canonical = document.createElement("link");
    canonical.rel = "canonical";
    document.head.append(canonical);
  }
  canonical.href = url;
}
