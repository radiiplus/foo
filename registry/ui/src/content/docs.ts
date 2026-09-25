import overview from "../../../../docs/README.md?raw";
import advanced from "../../../../docs/advanced.md?raw";
import compiler from "../../../../docs/compiler.md?raw";
import concurrency from "../../../../docs/concurrency.md?raw";
import intro from "../../../../docs/intro.md?raw";
import language from "../../../../docs/language.md?raw";
import library from "../../../../docs/library.md?raw";
import memory from "../../../../docs/memory.md?raw";
import packages from "../../../../docs/packages.md?raw";
import platforms from "../../../../docs/platforms.md?raw";
import reference from "../../../../docs/reference.md?raw";
import start from "../../../../docs/start.md?raw";
import syntax from "../../../../docs/syntax.md?raw";
import systems from "../../../../docs/systems.md?raw";

export type DocChapter = {
  id: string;
  title: string;
  shortTitle: string;
  description: string;
  group: "Start" | "Build" | "Master";
  source: string;
};

export const chapters: DocChapter[] = [
  { id: "overview", title: "The FOO Book", shortTitle: "Overview", description: "A guided path through a systems language designed to read like English.", group: "Start", source: overview },
  { id: "introduction", title: "Welcome to FOO", shortTitle: "Introduction", description: "Understand the language's goals, native backends, safety model, and place in the systems stack.", group: "Start", source: intro },
  { id: "getting-started", title: "Getting Started", shortTitle: "Getting started", description: "Install FOO, create a project, run your first program, and learn the everyday commands.", group: "Start", source: start },
  { id: "language", title: "The Language", shortTitle: "Language", description: "Learn declarations, functions, decisions, loops, word operators, and failure handling.", group: "Build", source: language },
  { id: "memory", title: "Data and Memory", shortTitle: "Data and memory", description: "Shape data with records, manage lifetimes with regions, and let sealing prevent unsafe access.", group: "Build", source: memory },
  { id: "systems", title: "Systems", shortTitle: "Systems", description: "Work with files, networks, processes, native C, and the operating system.", group: "Build", source: systems },
  { id: "concurrency", title: "Concurrency", shortTitle: "Concurrency", description: "Choose tasks, threads, and channels while keeping ownership and failure explicit.", group: "Build", source: concurrency },
  { id: "standard-library", title: "The Standard Library", shortTitle: "Standard library", description: "Explore FOO's focused modules for data, I/O, networking, time, and low-level control.", group: "Build", source: library },
  { id: "packages", title: "Packages", shortTitle: "Packages", description: "Add dependencies, lock exact versions, audit releases, and publish through the registry.", group: "Build", source: packages },
  { id: "compiler", title: "The Compiler", shortTitle: "Compiler", description: "Follow source through checking, planning, optimization, and the C or Zig backend.", group: "Master", source: compiler },
  { id: "platforms", title: "Platforms", shortTitle: "Platforms", description: "Target desktop, server, ARM, WebAssembly, and freestanding environments.", group: "Master", source: platforms },
  { id: "reference", title: "Quick Reference", shortTitle: "Reference", description: "A compact lookup for commands, vocabulary, types, control flow, and error handling.", group: "Master", source: reference },
  { id: "advanced", title: "Advanced FOO", shortTitle: "Advanced", description: "Reach compile-time execution, allocators, protocol policy, native code, and hardware tuning.", group: "Master", source: advanced },
  { id: "syntax", title: "Syntax Guide", shortTitle: "Syntax guide", description: "The complete dictionary of FOO declarations, types, operators, control flow, and interop.", group: "Master", source: syntax },
];

export const defaultChapter = chapters[0];

export function chapterById(id: string) {
  return chapters.find((chapter) => chapter.id === id) ?? defaultChapter;
}

export function docHref(href?: string) {
  if (!href) return href;
  const file = href.match(/(?:^|\/)(README|intro|start|language|memory|systems|concurrency|library|packages|compiler|platforms|reference|advanced|syntax)\.md(?:#(.*))?$/i);
  if (!file) return href;
  const ids: Record<string, string> = {
    README: "overview",
    intro: "introduction",
    start: "getting-started",
    language: "language",
    memory: "memory",
    systems: "systems",
    concurrency: "concurrency",
    library: "standard-library",
    packages: "packages",
    compiler: "compiler",
    platforms: "platforms",
    reference: "reference",
    advanced: "advanced",
    syntax: "syntax",
  };
  const id = ids[file[1]] ?? ids[file[1].toLowerCase()];
  return `/docs/${id}${file[2] ? `?section=${encodeURIComponent(file[2])}` : ""}`;
}
