import {
  ArrowRight,
  BookOpen,
  Boxes,
  Braces,
  Check,
  Code2,
  Cpu,
  Download,
  Gauge,
  GitFork,
  Layers3,
  PackageSearch,
  ShieldCheck,
  Terminal,
} from "lucide-react";
import benchmark from "../../../../benchmark/branch-allocator.json";
import { useEffect } from "react";

type LandingProps = {
  onEnter: () => void;
};

const stages = [
  ["Source", "4 files"],
  ["Checking", "0 errors"],
  ["Optimizing", "cache reused"],
  ["Linking", "native binary"],
] as const;

const modules = [
  ["file", "Read, write, seek, inspect, and manage filesystem resources."],
  ["http", "Start with requests, then reach headers, limits, redirects, and client policy."],
  ["task", "Use scoped tasks and channels while retaining lower-level scheduling control."],
  ["memory", "Choose automatic lifetimes or explicit arenas, regions, views, and transfer paths."],
] as const;

export default function Landing({ onEnter }: LandingProps) {
  useEffect(() => {
    const target = document.getElementById(window.location.hash.slice(1));
    if (target) requestAnimationFrame(() => target.scrollIntoView());
  }, []);

  return (
    <div className="h-dvh overflow-x-hidden overflow-y-auto bg-[#080808] text-[#f5f5f5] selection:bg-[#60D5DF] selection:text-black">
      <header className="sticky top-0 z-30 flex h-14 items-center justify-between border-b border-[#222] bg-[#080808]/95 px-5 backdrop-blur-sm sm:px-8">
        <a className="flex items-center gap-2.5" href="/" aria-label="FOO home">
          <img className="size-7" src="/icon.svg" alt="" />
          <span className="text-[11px] font-semibold tracking-[0.14em] text-[#777] uppercase">FOO</span>
        </a>
        <nav className="flex items-center gap-1 sm:gap-2" aria-label="Primary navigation">
          <a className="landing-nav-standard flex h-8 items-center gap-1.5 rounded-lg px-2.5 text-xs text-[#888] no-underline hover:bg-[#171717] hover:text-white" href="/standard">
            <Braces size={14} /> <span className="hidden md:inline">Standard</span>
          </a>
          <a className="landing-nav-download flex h-8 items-center gap-1.5 rounded-lg px-2.5 text-xs text-[#888] no-underline hover:bg-[#171717] hover:text-white" href="/downloads">
            <Download size={14} /> <span className="hidden md:inline">Downloads</span>
          </a>
          <a className="flex h-8 items-center gap-1.5 rounded-lg px-2.5 text-xs text-[#888] no-underline hover:bg-[#171717] hover:text-white" href="/docs/overview">
            <BookOpen size={14} /> <span className="hidden sm:inline">Docs</span>
          </a>
          <a className="hidden size-8 place-items-center rounded-lg text-[#777] hover:bg-[#171717] hover:text-white sm:grid" href="https://github.com/radiiplus/foo" target="_blank" rel="noreferrer" title="Open source repository">
            <GitFork size={15} />
          </a>
          <button className="flex h-8 items-center gap-2 rounded-lg bg-[#60D5DF] px-3 text-xs font-semibold text-[#0a0a0a] hover:bg-[#82E3EB]" type="button" onClick={onEnter}>
            Libraries <ArrowRight size={13} />
          </button>
        </nav>
      </header>

      <main>
        <section className="landing-hero mx-auto flex min-h-[calc(100svh-8.5rem)] w-full max-w-300 flex-col justify-center overflow-hidden px-5 py-10 sm:px-8 sm:py-12">
          <div className="landing-schematic" aria-hidden="true">
            <div className="landing-schematic-grid">
              {Array.from({ length: 9 }, (_, index) => <i className="vertical" style={{ left: `${index * 12.5}%` }} key={`v-${index}`} />)}
              {Array.from({ length: 7 }, (_, index) => <i className="horizontal" style={{ top: `${index * 16.666}%` }} key={`h-${index}`} />)}
            </div>
            <div className="landing-frame"><span /><span /></div>
            <div className="landing-pipeline">
              {Array.from({ length: 4 }, (_, index) => <b className={index === 2 ? "active" : ""} key={index}><i /></b>)}
            </div>
            <div className="landing-registers">
              {Array.from({ length: 24 }, (_, index) => <i className={index === 7 ? "hot" : index === 16 ? "warm" : ""} key={index} />)}
            </div>
            <i className="landing-signal signal-a" />
            <i className="landing-signal signal-b" />
            <i className="landing-signal signal-c" />
          </div>

          <div className="landing-hero-content">
            <img className="mb-5 size-14 sm:mb-6 sm:size-18" src="/icon.svg" alt="FOO" />
            <p className="mb-4 font-mono text-[10px] tracking-[0.18em] text-[#60D5DF] uppercase">Native systems, readable by design</p>
            <h1 className="max-w-220 text-4xl leading-[0.92] font-semibold tracking-normal text-[#f5f5f5] sm:text-6xl lg:text-7xl">FOO</h1>
            <p className="mt-4 max-w-150 text-sm leading-6 text-[#898989] sm:text-base">
              A sentence-like systems language with explicit safety, native C and Zig backends, and one toolchain from first file to published package.
            </p>
            <div className="landing-hero-actions mt-6 flex flex-wrap items-center gap-3">
              <a className="flex h-10 items-center gap-2 rounded-lg bg-[#60D5DF] px-4 text-sm font-semibold text-[#080808] no-underline hover:bg-[#82E3EB]" href="/docs/start">
                Start building <ArrowRight size={15} />
              </a>
              <button className="flex h-10 items-center gap-2 rounded-lg border border-[#303030] bg-[#111] px-4 text-sm text-[#aaa] hover:border-[#444] hover:text-white" type="button" onClick={onEnter}>
                Explore packages <PackageSearch size={14} />
              </button>
              <a className="flex h-10 items-center gap-2 rounded-lg border border-[#303030] bg-[#111] px-4 text-sm text-[#aaa] no-underline hover:border-[#444] hover:text-white" href="/downloads">
                Download <Download size={14} />
              </a>
            </div>
          </div>
        </section>

        <section className="border-y border-[#222] bg-[#0b0b0b]">
          <div className="mx-auto grid min-h-20 max-w-300 grid-cols-3 divide-x divide-[#222] px-3 sm:min-h-24 sm:px-8">
            <Feature icon={<Terminal size={15} />} title="One toolchain" detail="Build, test, benchmark, publish" />
            <Feature icon={<ShieldCheck size={15} />} title="Checked by default" detail="Types, failures, and ownership" />
            <Feature icon={<Cpu size={15} />} title="Native backends" detail="C and Zig, selected per project" />
          </div>
        </section>

        <section className="border-b border-[#222] bg-[#090909] px-5 py-18 sm:px-8 sm:py-24">
          <div className="mx-auto grid max-w-300 gap-12 lg:grid-cols-[0.82fr_1.18fr] lg:items-center lg:gap-20">
            <div>
              <Eyebrow icon={<Code2 size={13} />} text="Language / Current syntax" />
              <h2 className="mt-4 max-w-120 text-3xl leading-tight font-semibold tracking-normal text-[#f1f1f1] sm:text-4xl">Say what the program should do.</h2>
              <p className="mt-5 max-w-130 text-sm leading-7 text-[#858585]">
                FOO keeps types and failure visible without forcing every operation into ceremony. Programs may run at the top level, functions complete naturally, and word operators keep intent readable.
              </p>
              <div className="mt-8 grid gap-px border-y border-[#252525] bg-[#252525] sm:grid-cols-2">
                <Fact label="Failure" value="postfix try / fallback" />
                <Fact label="Mutation" value="increase / decrease" />
                <Fact label="Functions" value="defaults, labels, overloads" />
                <Fact label="Types" value="inferred or explicit" />
              </div>
              <a className="mt-7 inline-flex items-center gap-2 text-sm font-medium text-[#60D5DF] no-underline hover:text-[#8be6ed]" href="/docs/expressions">
                Explore the expression model <ArrowRight size={14} />
              </a>
            </div>

            <figure className="landing-code" aria-label="FOO source example">
              <figcaption><span><i />main.iv</span><span>FOO</span></figcaption>
              <pre><code><span className="foo-function">display</span> <span className="foo-string">&quot;Hello, world!&quot;</span>.</code></pre>
              <div className="landing-code-result"><span>OUTPUT</span><strong>Hello, world!</strong></div>
            </figure>
          </div>
        </section>

        <section className="border-b border-[#222] bg-[#0c0c0c] px-5 py-18 sm:px-8 sm:py-24">
          <div className="mx-auto max-w-300">
            <div className="grid gap-10 lg:grid-cols-[0.72fr_1.28fr] lg:gap-20">
              <div>
                <Eyebrow icon={<Gauge size={13} />} text="Toolchain / Visible work" />
                <h2 className="mt-4 text-3xl leading-tight font-semibold tracking-normal text-[#f1f1f1] sm:text-4xl">Fast paths stay quiet. Slow paths explain themselves.</h2>
                <p className="mt-5 text-sm leading-7 text-[#858585]">
                  Build output shows stages, jobs, cache reuse, elapsed time, and the selected path. Use <code className="landing-inline">--explain</code> when you need the compiler&apos;s reason without opening a wall of backend output.
                </p>
                <a className="mt-7 inline-flex items-center gap-2 text-sm font-medium text-[#e4ac52] no-underline hover:text-[#f2c978]" href="/docs/tuning">
                  Read optimization details <ArrowRight size={14} />
                </a>
              </div>

              <div className="landing-operation" aria-label="Example FOO build output">
                <header><span>FOO / BUILD</span><code>foo run</code></header>
                <div className="landing-stages">
                  {stages.map(([name, detail], index) => (
                    <div className="landing-stage" key={name}>
                      <span className="landing-stage-mark"><Check size={12} /></span>
                      <div><strong>{name}</strong><small>{detail}</small></div>
                      <code>{index === 2 ? "12 jobs" : "ready"}</code>
                    </div>
                  ))}
                </div>
                <div className="landing-progress" aria-label="Build complete"><i /><i /><i /><i /><i /><i /><i /><i /></div>
                <footer><strong>BUILD COMPLETE</strong><span>0 errors · 0 warnings · 0.82s</span></footer>
              </div>
            </div>

            <div className="mt-14 grid border-y border-[#262626] md:grid-cols-4 md:divide-x md:divide-[#262626]">
              <Tool icon={<Code2 size={15} />} command="foo run" detail="Check, compile, and execute" />
              <Tool icon={<Check size={15} />} command="foo test" detail="Run all or one test file" />
              <Tool icon={<Gauge size={15} />} command="foo benchmark" detail="Measure all or one scenario" />
              <Tool icon={<Boxes size={15} />} command="foo publish" detail="Verify, build, and publish" />
            </div>
          </div>
        </section>

        <section id="benchmark" className="border-b border-[#222] bg-[#080808] px-5 py-18 sm:px-8 sm:py-24">
          <div className="mx-auto grid max-w-300 gap-10 lg:grid-cols-[0.72fr_1.28fr] lg:items-end lg:gap-20">
            <div>
              <Eyebrow icon={<Gauge size={13} />} text="Benchmark / Branch workload" />
              <h2 className="mt-4 text-3xl leading-tight font-semibold tracking-normal text-[#f1f1f1] sm:text-4xl">Measured, with the conditions attached.</h2>
              <p className="mt-5 text-sm leading-7 text-[#858585]">
                {benchmark.work}. Measured {benchmark.iterations} times after {benchmark.warmup} warmups. {benchmark.method}
              </p>
              <p className="mt-3 text-xs leading-6 text-[#686868]">{benchmark.caution}</p>
              <a className="mt-7 inline-flex items-center gap-2 text-sm font-medium text-[#60D5DF] no-underline hover:text-[#8be6ed]" href="/docs/performance">
                Read the measurements <ArrowRight size={14} />
              </a>
            </div>

            <div className="landing-benchmark" aria-label="Branch workload FOO, Rust, and allocator results">
              <div className="landing-benchmark-head"><span>Strategy</span><span>Median</span><span>P95</span><span>Minimum</span></div>
              {benchmark.results.map((result) => (
                <div className="landing-benchmark-row" key={result.name}>
                  <strong>{result.name}</strong>
                  <span><small>Median</small><code>{result.medianMs.toFixed(2)} ms</code></span>
                  <span><small>P95</small><code>{result.p95Ms.toFixed(2)} ms</code></span>
                  <span><small>Minimum</small><code>{result.minimumMs.toFixed(2)} ms</code></span>
                </div>
              ))}
              <footer>
                <span>{benchmark.machine}</span>
                <span>Release / {benchmark.measuredAt}</span>
              </footer>
            </div>
          </div>
        </section>

        <section className="border-b border-[#222] bg-[#080808] px-5 py-18 sm:px-8 sm:py-24">
          <div className="mx-auto max-w-300">
            <div className="grid gap-8 lg:grid-cols-[0.78fr_1.22fr] lg:gap-20">
              <div>
                <Eyebrow icon={<Layers3 size={13} />} text="Standard library / Two levels" />
                <h2 className="mt-4 text-3xl leading-tight font-semibold tracking-normal text-[#f1f1f1] sm:text-4xl">Simple first. Lower-level when it matters.</h2>
                <p className="mt-5 text-sm leading-7 text-[#858585]">
                  Everyday APIs cover the common path. The same modules expose explicit resource, policy, memory, and platform controls for systems work without sending advanced users to a different ecosystem.
                </p>
                <a className="mt-7 inline-flex items-center gap-2 text-sm font-medium text-[#60D5DF] no-underline hover:text-[#8be6ed]" href="/standard">
                  Browse public interfaces <ArrowRight size={14} />
                </a>
              </div>

              <div className="border-t border-[#292929]">
                {modules.map(([name, detail], index) => (
                  <a className="landing-module" href={`/standard#${name}`} key={name}>
                    <span>{String(index + 1).padStart(2, "0")}</span>
                    <strong>{name}</strong>
                    <p>{detail}</p>
                    <ArrowRight size={14} />
                  </a>
                ))}
              </div>
            </div>
          </div>
        </section>

        <section className="border-b border-[#222] bg-[#0b0b0b] px-5 py-18 sm:px-8 sm:py-24">
          <div className="mx-auto max-w-300">
            <div className="max-w-150">
              <Eyebrow icon={<Boxes size={13} />} text="Project / Complete workflow" />
              <h2 className="mt-4 text-3xl leading-tight font-semibold tracking-normal text-[#f1f1f1] sm:text-4xl">A project starts ready for more than a demo.</h2>
              <p className="mt-5 text-sm leading-7 text-[#858585]">Create a new directory or initialize the current one. Source, tests, benchmarks, named entries, dependency locking, and editor diagnostics share the same project model.</p>
            </div>
            <div className="landing-project mt-12">
              <Project name="src/" detail="Application and library source" accent="#60D5DF" />
              <Project name="test/" detail="Focused and full correctness runs" accent="#39FF88" />
              <Project name="benchmark/" detail="Warm, repeated performance scenarios" accent="#e4ac52" />
              <Project name="project.json" detail="Default and named entry points" accent="#b94d79" />
            </div>
            <div className="mt-8 flex flex-wrap gap-3">
              <code className="landing-command"><span>$</span> foo new .</code>
              <code className="landing-command"><span>$</span> foo watch</code>
              <code className="landing-command"><span>$</span> foo test test/network.iv</code>
            </div>
          </div>
        </section>

        <section className="bg-[#090909] px-5 py-18 sm:px-8 sm:py-24">
          <div className="mx-auto grid max-w-300 gap-10 lg:grid-cols-[1fr_auto] lg:items-end">
            <div>
              <p className="font-mono text-[10px] tracking-[0.18em] text-[#b94d79] uppercase">Language · Toolchain · Registry</p>
              <h2 className="mt-4 max-w-180 text-3xl leading-tight font-semibold tracking-normal text-[#f1f1f1] sm:text-5xl">From a readable sentence to a native program.</h2>
              <p className="mt-5 max-w-150 text-sm leading-7 text-[#858585]">Install the current release, follow the FOO Book, or inspect the compiler and runtime directly.</p>
            </div>
            <div className="flex flex-wrap gap-3">
              <a className="flex h-10 items-center gap-2 rounded-lg bg-[#60D5DF] px-4 text-sm font-semibold text-[#080808] no-underline hover:bg-[#82E3EB]" href="/downloads">Get FOO <Download size={14} /></a>
              <a className="flex h-10 items-center gap-2 rounded-lg border border-[#303030] px-4 text-sm text-[#aaa] no-underline hover:border-[#444] hover:text-white" href="/docs/overview">Read the book <BookOpen size={14} /></a>
              <a className="grid size-10 place-items-center rounded-lg border border-[#303030] text-[#888] hover:border-[#444] hover:text-white" href="https://github.com/radiiplus/foo" target="_blank" rel="noreferrer" title="View FOO on GitHub"><GitFork size={15} /></a>
            </div>
          </div>
        </section>
      </main>

      <footer className="border-t border-[#222] bg-[#080808] px-5 py-7 sm:px-8">
        <div className="mx-auto flex max-w-300 flex-col gap-4 text-[11px] text-[#656565] sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-center gap-2"><img className="size-5" src="/icon.svg" alt="" /><span>FOO programming language</span></div>
          <nav className="flex flex-wrap gap-x-5 gap-y-2" aria-label="Footer navigation">
            <a className="text-[#777] no-underline hover:text-white" href="/docs/status">Feature status</a>
            <a className="text-[#777] no-underline hover:text-white" href="/llm.txt">llm.txt</a>
            <a className="text-[#777] no-underline hover:text-white" href="/sitemap.xml">Sitemap</a>
            <a className="text-[#777] no-underline hover:text-white" href="https://github.com/radiiplus/foo" target="_blank" rel="noreferrer">Source</a>
          </nav>
        </div>
      </footer>
    </div>
  );
}

function Feature({ icon, title, detail }: { icon: React.ReactNode; title: string; detail: string }) {
  return <div className="flex min-w-0 items-center gap-2 px-2 sm:gap-3 sm:px-5"><span className="shrink-0 text-[#60D5DF]">{icon}</span><div className="min-w-0"><p className="text-[10px] text-[#d8d8d8] sm:text-xs">{title}</p><p className="mt-1 truncate text-[9px] text-[#5f5f5f] max-sm:hidden">{detail}</p></div></div>;
}

function Eyebrow({ icon, text }: { icon: React.ReactNode; text: string }) {
  return <p className="flex items-center gap-2 font-mono text-[9px] tracking-[0.16em] text-[#60D5DF] uppercase"><span>{icon}</span>{text}</p>;
}

function Fact({ label, value }: { label: string; value: string }) {
  return <div className="bg-[#090909] px-3 py-4"><p className="font-mono text-[8px] tracking-[0.12em] text-[#575757] uppercase">{label}</p><p className="mt-1.5 text-[11px] text-[#b7b7b7]">{value}</p></div>;
}

function Tool({ icon, command, detail }: { icon: React.ReactNode; command: string; detail: string }) {
  return <div className="flex items-start gap-3 border-b border-[#262626] px-3 py-5 last:border-b-0 md:border-b-0 md:px-5"><span className="mt-0.5 text-[#e4ac52]">{icon}</span><div><code className="text-[11px] text-[#ddd]">{command}</code><p className="mt-1 text-[10px] leading-4 text-[#606060]">{detail}</p></div></div>;
}

function Project({ name, detail, accent }: { name: string; detail: string; accent: string }) {
  return <div className="landing-project-item"><i style={{ backgroundColor: accent }} /><code>{name}</code><p>{detail}</p></div>;
}
