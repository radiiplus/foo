import overview from "../../../../docs/README.md?raw";
import advanced from "../../../../docs/advanced.md?raw";
import benchmarking from "../../../../docs/benchmarking.md?raw";
import cache from "../../../../docs/cache.md?raw";
import capabilities from "../../../../docs/capabilities.md?raw";
import collections from "../../../../docs/collections.md?raw";
import compiler from "../../../../docs/compiler.md?raw";
import concurrency from "../../../../docs/concurrency.md?raw";
import dependencies from "../../../../docs/dependencies.md?raw";
import diagnostics from "../../../../docs/diagnostics.md?raw";
import freestanding from "../../../../docs/freestanding.md?raw";
import hardware from "../../../../docs/hardware.md?raw";
import status from "../../../../docs/status.md?raw";
import functions from "../../../../docs/functions.md?raw";
import start from "../../../../docs/start.md?raw";
import language from "../../../../docs/language.md?raw";
import library from "../../../../docs/library.md?raw";
import linking from "../../../../docs/linking.md?raw";
import memory from "../../../../docs/memory.md?raw";
import modules from "../../../../docs/modules.md?raw";
import naming from "../../../../docs/naming.md?raw";
import packages from "../../../../docs/packages.md?raw";
import patterns from "../../../../docs/patterns.md?raw";
import performance from "../../../../docs/performance.md?raw";
import platforms from "../../../../docs/platforms.md?raw";
import projects from "../../../../docs/projects.md?raw";
import qbe from "../../../../docs/qbe.md?raw";
import reference from "../../../../docs/reference.md?raw";
import releasing from "../../../../docs/releasing.md?raw";
import runtime from "../../../../docs/runtime.md?raw";
import catalog from "../../../../docs/catalog.md?raw";
import syntax from "../../../../docs/syntax.md?raw";
import systems from "../../../../docs/systems.md?raw";
import testing from "../../../../docs/testing.md?raw";
import tuning from "../../../../docs/tuning.md?raw";
import vendor from "../../../../docs/vendor.md?raw";

export type Chapter = {
  id: string;
  title: string;
  short: string;
  description: string;
  group: "Learn" | "Build" | "Reference";
  source: string;
};

export const chapters: Chapter[] = [
  { id: "overview", title: "The FOO Book", short: "Overview", description: "A guided path through a systems language designed to read like English.", group: "Learn", source: overview },
  { id: "start", title: "Getting Started", short: "Getting started", description: "Install FOO, create a project, run your first program, and learn the everyday commands.", group: "Learn", source: start },
  { id: "language", title: "The Language", short: "Language", description: "Learn statements, values, operators, decisions, and loops in one chapter.", group: "Learn", source: language },
  { id: "functions", title: "Functions", short: "Functions", description: "Define typed operations, handle recoverable errors, and clean up resources.", group: "Learn", source: functions },
  { id: "collections", title: "Collections", short: "Collections", description: "Build sequences, maps, sets, queues, and stacks while keeping storage responsibility and cleanup visible.", group: "Build", source: collections },
  { id: "modules", title: "Modules and Packages", short: "Modules and packages", description: "Import files and standard modules, control visibility, and install dependencies repeatably.", group: "Build", source: modules },
  { id: "projects", title: "Projects and Entry Points", short: "Projects and entries", description: "Configure project.ivc, named runnable entries, focused tests, benchmarks, watches, and build backends.", group: "Build", source: projects },
  { id: "memory", title: "Data and Memory", short: "Data and memory", description: "Shape data with records, group memory for cleanup, and prevent access after data is no longer valid.", group: "Build", source: memory },
  { id: "patterns", title: "Patterns with Today's Language", short: "Current patterns", description: "Build validated values, data converters, state machines, permissions, transactions, typed time, and repeatable checks.", group: "Build", source: patterns },
  { id: "systems", title: "Systems", short: "Systems", description: "Work with files, networks, processes, native C, and the operating system.", group: "Build", source: systems },
  { id: "concurrency", title: "Concurrency", short: "Concurrency", description: "Run overlapping work with tasks, threads, and channels while keeping cleanup and failure explicit.", group: "Build", source: concurrency },
  { id: "library", title: "The Standard Library", short: "Standard library", description: "Explore FOO's focused modules for data, I/O, networking, time, and low-level control.", group: "Build", source: library },
  { id: "catalog", title: "Standard Library Index", short: "Library index", description: "Find every shipped module by task, compare abstraction levels, and read common API surfaces.", group: "Build", source: catalog },
  { id: "packages", title: "Packages", short: "Packages", description: "Add dependencies, lock exact versions, audit releases, and publish through the registry.", group: "Build", source: packages },
  { id: "testing", title: "Testing", short: "Testing", description: "Write isolated tests, use assertions, filter runs, watch changes, and configure native fixtures.", group: "Build", source: testing },
  { id: "benchmarking", title: "Benchmarking", short: "Benchmarking", description: "Measure complete programs with warmups, repeated samples, and clear summary statistics.", group: "Build", source: benchmarking },
  { id: "performance", title: "Performance", short: "Performance", description: "Review measured FOO program times with their workloads, targets, and sample ranges.", group: "Build", source: performance },
  { id: "tuning", title: "Optimization Under the Hood", short: "Optimization", description: "Understand execution specialization, boundary and work elimination, fusion rules, adaptive paths, and measured evidence.", group: "Build", source: tuning },
  { id: "compiler", title: "The Compiler", short: "Compiler", description: "Follow source through checking, planning, and QBE code generation.", group: "Reference", source: compiler },
  { id: "diagnostics", title: "Diagnostics", short: "Diagnostics", description: "Read grouped colored errors and consume exact verbose, JSON, and editor diagnostics.", group: "Reference", source: diagnostics },
  { id: "platforms", title: "Platforms", short: "Platforms", description: "Target desktop, server, ARM, WebAssembly, and freestanding environments.", group: "Reference", source: platforms },
  { id: "status", title: "Feature Status", short: "Feature status", description: "Check current language and tool support, target gates, and limits.", group: "Reference", source: status },
  { id: "releasing", title: "Building Release Binaries", short: "Releases", description: "Stage compiler packages, build installers, and sign release binaries.", group: "Reference", source: releasing },
  { id: "reference", title: "Quick Reference", short: "Reference", description: "A compact lookup for commands, vocabulary, types, control flow, and error handling.", group: "Reference", source: reference },
  { id: "advanced", title: "Advanced FOO", short: "Advanced", description: "Run work while building, control memory placement and communication rules, use native code, and tune hardware paths.", group: "Reference", source: advanced },
  { id: "syntax", title: "Syntax Guide", short: "Syntax guide", description: "A compact reference for canonical declarations, types, operators, control flow, failure handling, and interop.", group: "Reference", source: syntax },
  { id: "qbe", title: "QBE Backend Support", short: "QBE support", description: "Review qualified targets, available products, runtime services, and current limits.", group: "Reference", source: qbe },
  { id: "cache", title: "Build Cache", short: "Build cache", description: "Understand when compiler artifacts are reused or rebuilt.", group: "Reference", source: cache },
  { id: "dependencies", title: "Build Dependencies", short: "Dependencies", description: "Find the native tools and target inputs needed for a build.", group: "Reference", source: dependencies },
  { id: "linking", title: "Linking and Native Inputs", short: "Linking", description: "Review target link inputs and their build identities.", group: "Reference", source: linking },
  { id: "runtime", title: "Runtime", short: "Runtime", description: "See where hosted services and target runtime fragments come from.", group: "Reference", source: runtime },
  { id: "freestanding", title: "Freestanding Runtime", short: "Freestanding", description: "Use runtime-free products and the host callback contract.", group: "Reference", source: freestanding },
  { id: "hardware", title: "Hardware Targets", short: "Hardware", description: "Review freestanding target setup and tested device gates.", group: "Reference", source: hardware },
  { id: "capabilities", title: "Systems Capabilities", short: "Capabilities", description: "Understand capability levels and target availability.", group: "Reference", source: capabilities },
  { id: "naming", title: "Naming", short: "Naming", description: "Follow source and repository naming rules.", group: "Reference", source: naming },
  { id: "vendor", title: "Vendored Dependencies", short: "Vendor", description: "Review bundled dependency provenance and update rules.", group: "Reference", source: vendor },
];

export const fallback = chapters[0];

const aliases: Record<string, string> = {
  introduction: "overview",
  intro: "overview",
  "getting-started": "start",
  "control-flow": "language",
  basics: "language",
  variables: "language",
  types: "language",
  operators: "language",
  flow: "language",
  errors: "functions",
  expressions: "functions",
  foundations: "language",
  "standard-library": "library",
  "stdlib-reference": "catalog",
  "feature-status": "status",
};

export function chapter(id: string) {
  const key = aliases[id] ?? id;
  return chapters.find((item) => item.id === key) ?? fallback;
}

export function link(href?: string) {
  if (!href) return href;
  if (href.startsWith("../"))
    return new URL(href, "https://github.com/radiiplus/foo/blob/main/docs/").href;
  const file = href.match(/^(?:\.\/)?([a-z0-9-]+)\.md(?:#(.*))?$/i);
  if (!file) return href;
  const stem = file[1].toLowerCase();
  const id = stem === "readme" ? "overview" : aliases[stem] ?? stem;
  if (!chapters.some((item) => item.id === id)) return href;
  return `/docs/${id}${file[2] ? `?section=${encodeURIComponent(file[2])}` : ""}`;
}
