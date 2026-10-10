import overview from "../../../../docs/README.md?raw";
import advanced from "../../../../docs/advanced.md?raw";
import audit from "../../../../docs/audit.md?raw";
import basics from "../../../../docs/basics.md?raw";
import benchmarking from "../../../../docs/benchmarking.md?raw";
import collections from "../../../../docs/collections.md?raw";
import compiler from "../../../../docs/compiler.md?raw";
import concurrency from "../../../../docs/concurrency.md?raw";
import flow from "../../../../docs/flow.md?raw";
import foundations from "../../../../docs/foundations.md?raw";
import diagnostics from "../../../../docs/diagnostics.md?raw";
import errors from "../../../../docs/errors.md?raw";
import expressions from "../../../../docs/expressions.md?raw";
import status from "../../../../docs/status.md?raw";
import functions from "../../../../docs/functions.md?raw";
import intro from "../../../../docs/intro.md?raw";
import language from "../../../../docs/language.md?raw";
import library from "../../../../docs/library.md?raw";
import memory from "../../../../docs/memory.md?raw";
import modules from "../../../../docs/modules.md?raw";
import operators from "../../../../docs/operators.md?raw";
import packages from "../../../../docs/packages.md?raw";
import patterns from "../../../../docs/patterns.md?raw";
import performance from "../../../../docs/performance.md?raw";
import platforms from "../../../../docs/platforms.md?raw";
import projects from "../../../../docs/projects.md?raw";
import reference from "../../../../docs/reference.md?raw";
import start from "../../../../docs/start.md?raw";
import catalog from "../../../../docs/catalog.md?raw";
import syntax from "../../../../docs/syntax.md?raw";
import systems from "../../../../docs/systems.md?raw";
import testing from "../../../../docs/testing.md?raw";
import tuning from "../../../../docs/tuning.md?raw";
import types from "../../../../docs/types.md?raw";
import variables from "../../../../docs/variables.md?raw";

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
  { id: "introduction", title: "Welcome to FOO", short: "Introduction", description: "Understand the language's goals, native backends, safety model, and place in the systems stack.", group: "Learn", source: intro },
  { id: "start", title: "Getting Started", short: "Getting started", description: "Install FOO, create a project, run your first program, and learn the everyday commands.", group: "Learn", source: start },
  { id: "basics", title: "FOO Basics", short: "Basics", description: "Learn statements, blocks, comments, top-level execution, project files, and the first commands to run.", group: "Learn", source: basics },
  { id: "variables", title: "Variables", short: "Variables", description: "Declare fixed and changing values, let the compiler work out obvious types, and learn where names are visible.", group: "Learn", source: variables },
  { id: "types", title: "Types and Values", short: "Types and values", description: "Use built-in and grouped values, represent missing data, and handle results that can fail.", group: "Learn", source: types },
  { id: "operators", title: "Operators", short: "Operators", description: "Write arithmetic, comparisons, Boolean logic, and grouped expressions with FOO's word operators.", group: "Learn", source: operators },
  { id: "flow", title: "Conditions and Loops", short: "Conditions and loops", description: "Choose paths with when, otherwise, and match, then repeat work with while and for each.", group: "Learn", source: flow },
  { id: "functions", title: "Functions", short: "Functions", description: "Define typed operations, return values, expose public APIs, and write constrained generics.", group: "Learn", source: functions },
  { id: "expressions", title: "Expressions and English Grammar", short: "Expressions", description: "Use sentence calls, flexible arguments, shared function names, local functions, and deliberate value updates.", group: "Learn", source: expressions },
  { id: "foundations", title: "Language Foundations", short: "Foundations", description: "Understand missing values, reusable typed code, modules, memory, overlapping work, time, testing, and future design boundaries.", group: "Learn", source: foundations },
  { id: "language", title: "The Language", short: "Language", description: "Learn declarations, functions, decisions, loops, word operators, and failure handling.", group: "Build", source: language },
  { id: "collections", title: "Collections", short: "Collections", description: "Build sequences, maps, sets, queues, and stacks while keeping storage responsibility and cleanup visible.", group: "Build", source: collections },
  { id: "errors", title: "Error Handling", short: "Error handling", description: "Propagate failures with postfix try, recover with fallback, and guarantee cleanup with after.", group: "Build", source: errors },
  { id: "modules", title: "Modules and Packages", short: "Modules and packages", description: "Import files and standard modules, control visibility, and install dependencies repeatably.", group: "Build", source: modules },
  { id: "projects", title: "Projects and Entry Points", short: "Projects and entries", description: "Configure project.json, named runnable entries, focused tests, benchmarks, watches, and build backends.", group: "Build", source: projects },
  { id: "memory", title: "Data and Memory", short: "Data and memory", description: "Shape data with records, group memory for cleanup, and prevent access after data is no longer valid.", group: "Build", source: memory },
  { id: "patterns", title: "Patterns with Today's Language", short: "Current patterns", description: "Build validated values, data converters, state machines, permissions, transactions, typed time, and repeatable checks.", group: "Build", source: patterns },
  { id: "systems", title: "Systems", short: "Systems", description: "Work with files, networks, processes, native C, and the operating system.", group: "Build", source: systems },
  { id: "concurrency", title: "Concurrency", short: "Concurrency", description: "Run overlapping work with tasks, threads, and channels while keeping cleanup and failure explicit.", group: "Build", source: concurrency },
  { id: "library", title: "The Standard Library", short: "Standard library", description: "Explore FOO's focused modules for data, I/O, networking, time, and low-level control.", group: "Build", source: library },
  { id: "catalog", title: "Standard Library Index", short: "Library index", description: "Find every shipped module by task, compare abstraction levels, and read common API surfaces.", group: "Build", source: catalog },
  { id: "packages", title: "Packages", short: "Packages", description: "Add dependencies, lock exact versions, audit releases, and publish through the registry.", group: "Build", source: packages },
  { id: "testing", title: "Testing", short: "Testing", description: "Write isolated tests, use assertions, filter runs, watch changes, and configure native fixtures.", group: "Build", source: testing },
  { id: "benchmarking", title: "Benchmarking", short: "Benchmarking", description: "Measure complete programs with warmups, repeated samples, and clear summary statistics.", group: "Build", source: benchmarking },
  { id: "performance", title: "Performance", short: "Performance", description: "Review current benchmark methodology, sequence behavior, runtime telemetry, focused results, and profiling decisions.", group: "Build", source: performance },
  { id: "audit", title: "Optimization Audit", short: "Optimization audit", description: "Inspect the packed bitmap optimization, paired measurements, and the limits of each result.", group: "Build", source: audit },
  { id: "tuning", title: "Optimization Under the Hood", short: "Optimization", description: "Understand execution specialization, boundary and work elimination, fusion rules, adaptive paths, and measured evidence.", group: "Build", source: tuning },
  { id: "compiler", title: "The Compiler", short: "Compiler", description: "Follow source through checking, planning, speed improvements, and C or Zig code generation.", group: "Reference", source: compiler },
  { id: "diagnostics", title: "Diagnostics", short: "Diagnostics", description: "Read grouped colored errors and consume exact verbose, JSON, and editor diagnostics.", group: "Reference", source: diagnostics },
  { id: "platforms", title: "Platforms", short: "Platforms", description: "Target desktop, server, ARM, WebAssembly, and freestanding environments.", group: "Reference", source: platforms },
  { id: "status", title: "Feature Status", short: "Feature status", description: "Check which language, memory, concurrency, interop, and tooling features FOO v1 implements.", group: "Reference", source: status },
  { id: "reference", title: "Quick Reference", short: "Reference", description: "A compact lookup for commands, vocabulary, types, control flow, and error handling.", group: "Reference", source: reference },
  { id: "advanced", title: "Advanced FOO", short: "Advanced", description: "Run work while building, control memory placement and communication rules, use native code, and tune hardware paths.", group: "Reference", source: advanced },
  { id: "syntax", title: "Syntax Guide", short: "Syntax guide", description: "A compact reference for canonical declarations, types, operators, control flow, failure handling, and interop.", group: "Reference", source: syntax },
];

export const fallback = chapters[0];

export function chapter(id: string) {
  const aliases: Record<string, string> = {
    "getting-started": "start",
    "control-flow": "flow",
    "standard-library": "library",
    "stdlib-reference": "catalog",
    "feature-status": "status",
  };
  const key = aliases[id] ?? id;
  return chapters.find((item) => item.id === key) ?? fallback;
}

export function link(href?: string) {
  if (!href) return href;
  const file = href.match(/(?:^|\/)(README|intro|start|basics|variables|types|operators|flow|functions|expressions|foundations|language|collections|errors|modules|projects|memory|patterns|systems|concurrency|library|catalog|packages|testing|benchmarking|performance|audit|tuning|compiler|diagnostics|platforms|status|reference|advanced|syntax)\.md(?:#(.*))?$/i);
  if (!file) return href;
  const ids: Record<string, string> = {
    README: "overview",
    intro: "introduction",
    start: "start",
    basics: "basics",
    variables: "variables",
    types: "types",
    operators: "operators",
    flow: "flow",
    functions: "functions",
    expressions: "expressions",
    foundations: "foundations",
    language: "language",
    collections: "collections",
    errors: "errors",
    modules: "modules",
    projects: "projects",
    memory: "memory",
    patterns: "patterns",
    systems: "systems",
    concurrency: "concurrency",
    library: "library",
    catalog: "catalog",
    packages: "packages",
    testing: "testing",
    benchmarking: "benchmarking",
    performance: "performance",
    tuning: "tuning",
    compiler: "compiler",
    diagnostics: "diagnostics",
    platforms: "platforms",
    status: "status",
    reference: "reference",
    advanced: "advanced",
    syntax: "syntax",
  };
  const id = ids[file[1]] ?? ids[file[1].toLowerCase()];
  return `/docs/${id}${file[2] ? `?section=${encodeURIComponent(file[2])}` : ""}`;
}
