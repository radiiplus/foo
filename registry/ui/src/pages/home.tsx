import { lazy, Suspense, useCallback, useEffect, useRef, useState } from "react";

import { Header } from "../components/header";
import { Backdrop } from "../components/backdrop";
import { Palette } from "../components/palette";
import { seo } from "../utils/seo";
import Detail from "./detail";
import Discover, { type Action } from "./discover";
import Landing from "./landing";
import Standard from "./standard";

const Docs = lazy(() => import("./docs"));
const Downloads = lazy(() => import("./downloads"));

type Route = { page: "landing" } | { page: "registry" } | { page: "standard" } | { page: "detail"; name: string } | { page: "docs"; chapter: string; section?: string } | { page: "downloads" };

function Home() {
  const [palette, setPalette] = useState(false);
  const [route, setRoute] = useState<Route>(() => routeFromLocation());
  const [action, setAction] = useState<Action>({ id: 0, type: "reset" });
  const searchRef = useRef<HTMLInputElement>(null);

  const command = useCallback((type: Action["type"], value?: string) => {
    if (type !== "tag") navigate();
    setAction({ id: Date.now(), type, value });
  }, []);

  useEffect(() => {
    const onNavigate = () => setRoute(routeFromLocation());
    const onKey = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setPalette((value) => !value);
      }
      if (event.key === "Escape") setPalette(false);
    };
    window.addEventListener("popstate", onNavigate);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("popstate", onNavigate);
      window.removeEventListener("keydown", onKey);
    };
  }, []);

  useEffect(() => {
    if (route.page === "docs" || route.page === "detail") return;
    const values = {
      landing: ["FOO Language - Documentation, Packages, and Downloads", "A readable systems language with native performance, explicit safety, documentation, packages, and toolchain downloads."],
      registry: ["FOO Package Registry", "Discover verified packages for the FOO programming language and inspect their versions, APIs, and documentation."],
      standard: ["FOO Standard Library", "Browse the FOO standard library for files, networking, collections, concurrency, cryptography, and low-level systems work."],
      downloads: ["Download FOO", "Download the latest FOO compiler and toolchain release for Windows, Linux x64, and Linux ARM64."],
    } as const;
    const [title, description] = values[route.page];
    seo({ title, description });
  }, [route]);

  if (route.page === "landing") {
    return <Landing onEnter={(query) => navigateTo(query ? `/registry?q=${encodeURIComponent(query)}` : "/registry")} />;
  }

  const selected = route.page === "detail" ? route.name : "";

  return (
    <div className="registry-app-shell flex h-dvh flex-col overflow-hidden bg-[#080808] text-[#f5f5f5] selection:bg-[#60D5DF] selection:text-black">
      <Backdrop />
      <Header
        active={route.page === "docs" ? "docs" : route.page === "downloads" ? "downloads" : route.page === "standard" ? "standard" : "libraries"}
        onPalette={() => setPalette(true)}
        onLibraries={() => command("reset")}
        onStandard={() => navigateTo("/standard")}
        onDocs={() => navigateDocs()}
        onDownloads={() => navigateTo("/downloads")}
      />
      <div className="flex min-h-0 flex-1">
        <main className={`min-w-0 flex-1 ${selected || route.page === "docs" || route.page === "downloads" ? "overflow-y-auto" : "overflow-hidden"}`}>
          {route.page === "docs"
            ? <Suspense fallback={<div className="grid h-full place-items-center font-mono text-[10px] text-[#707070]">Opening the FOO Book...</div>}><Docs id={route.chapter} section={route.section} /></Suspense>
            : route.page === "downloads"
            ? <Suspense fallback={<div className="grid h-full place-items-center font-mono text-[10px] text-[#707070]">Loading releases...</div>}><Downloads /></Suspense>
            : route.page === "standard"
            ? <Standard onOpen={(name, symbolId) => navigateTo(`/package/${encodeURIComponent(name)}${symbolId ? `?view=api&api=${encodeURIComponent(symbolId)}` : ""}`, window.location.pathname + window.location.search)} />
            : selected
            ? <Detail key={selected} name={selected} backLabel={String(window.history.state?.back ?? "").startsWith("/standard") ? "Standard library" : "Libraries"} onBack={() => navigateTo(window.history.state?.back ?? "/registry")} onTag={(tag) => { navigate(); setAction({ id: Date.now(), type: "tag", value: tag }); }} />
            : <Discover action={action} inputRef={searchRef} onOpen={(name) => navigateTo(`/package/${encodeURIComponent(name)}`, window.location.pathname + window.location.search)} />}
        </main>
      </div>
      <Palette
        open={palette}
        onClose={() => setPalette(false)}
        onSearch={() => command("focus")}
        onPackages={() => command("reset")}
        onCategories={() => command("categories")}
        onStandard={() => navigateTo("/standard")}
        onDocs={() => navigateDocs()}
        onDownloads={() => navigateTo("/downloads")}
      />
    </div>
  );
}

export default Home;

function routeFromLocation(): Route {
  const path = window.location.pathname.replace(/\/+$/, "") || "/";
  if (path.startsWith("/package/")) return { page: "detail", name: decodeURIComponent(path.slice(9)) };
  if (path === "/docs" || path.startsWith("/docs/")) {
    const chapter = path === "/docs" ? "overview" : decodeURIComponent(path.slice(6));
    return { page: "docs", chapter, section: new URLSearchParams(window.location.search).get("section") ?? undefined };
  }
  if (path === "/registry") return { page: "registry" };
  if (path === "/standard") return { page: "standard" };
  if (path === "/downloads") return { page: "downloads" };
  return { page: "landing" };
}

function navigateDocs(chapter = "overview") {
  navigateTo(`/docs/${encodeURIComponent(chapter)}`);
}

function navigate(name?: string) {
  navigateTo(name ? `/package/${encodeURIComponent(name)}` : "/registry");
}

function navigateTo(path: string, back?: string) {
  window.history.pushState(back ? { back } : {}, "", path);
  window.dispatchEvent(new PopStateEvent("popstate"));
}
