import { lazy, Suspense, useCallback, useEffect, useRef, useState } from "react";

import { Header } from "../components/header";
import { Palette } from "../components/palette";
import { Sidebar } from "../components/sidebar";
import { health } from "../utils/registry";
import Detail from "./detail";
import Discover, { type Action } from "./discover";
import Landing from "./landing";
import Standard from "./standard";

const Docs = lazy(() => import("./docs"));
const Downloads = lazy(() => import("./downloads"));

type State = "checking" | "connected" | "offline";
type Route = { page: "landing" } | { page: "registry" } | { page: "standard" } | { page: "detail"; name: string } | { page: "docs"; chapter: string; section?: string } | { page: "downloads" };

function Home() {
  const [state, setState] = useState<State>("checking");
  const [palette, setPalette] = useState(false);
  const [route, setRoute] = useState<Route>(() => routeFromLocation());
  const [action, setAction] = useState<Action>({ id: 0, type: "reset" });
  const searchRef = useRef<HTMLInputElement>(null);

  const command = useCallback((type: Action["type"], value?: string) => {
    if (type !== "tag") navigate();
    setAction({ id: Date.now(), type, value });
  }, []);

  useEffect(() => {
    void health().then(() => setState("connected")).catch(() => setState("offline"));
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

  if (route.page === "landing") {
    return <Landing onEnter={() => navigate()} />;
  }

  const selected = route.page === "detail" ? route.name : "";

  return (
    <div className="flex h-dvh flex-col overflow-hidden bg-[#080808] text-[#f5f5f5] selection:bg-[#60D5DF] selection:text-black">
      <Header
        active={route.page === "docs" ? "docs" : route.page === "downloads" ? "downloads" : route.page === "standard" ? "standard" : "libraries"}
        onPalette={() => setPalette(true)}
        onLibraries={() => command("reset")}
        onStandard={() => navigateTo("/standard")}
        onDocs={() => navigateDocs()}
        onDownloads={() => navigateTo("/downloads")}
      />
      <div className="flex min-h-0 flex-1">
        <Sidebar
          active={route.page === "docs" ? "docs" : route.page === "downloads" ? "downloads" : route.page === "standard" ? "standard" : selected ? "detail" : "discover"}
          online={state === "connected"}
          onDiscover={() => command("reset")}
          onPackages={() => command("reset")}
          onCategories={() => command("categories")}
          onTags={() => command("tags")}
          onStandard={() => navigateTo("/standard")}
          onDocs={() => navigateDocs()}
          onDownloads={() => navigateTo("/downloads")}
        />
        <main className={`min-w-0 flex-1 ${selected || route.page === "docs" || route.page === "downloads" ? "overflow-y-auto" : "overflow-hidden"}`}>
          {route.page === "docs"
            ? <Suspense fallback={<div className="grid h-full place-items-center font-mono text-[10px] text-[#707070]">Opening the FOO Book...</div>}><Docs chapterId={route.chapter} section={route.section} /></Suspense>
            : route.page === "downloads"
            ? <Suspense fallback={<div className="grid h-full place-items-center font-mono text-[10px] text-[#707070]">Loading releases...</div>}><Downloads /></Suspense>
            : route.page === "standard"
            ? <Standard onOpen={(name) => navigate(name)} />
            : selected
            ? <Detail key={selected} name={selected} onBack={() => navigate()} onTag={(tag) => { navigate(); setAction({ id: Date.now(), type: "tag", value: tag }); }} />
            : <Discover action={action} inputRef={searchRef} onOpen={(name) => navigate(name)} />}
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

function navigateTo(path: string) {
  window.history.pushState({}, "", path);
  window.dispatchEvent(new PopStateEvent("popstate"));
}
