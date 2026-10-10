import { ArrowRight, BookOpen, Braces, Check, Copy, Download, GitFork, PackageSearch } from "lucide-react";
import { lazy, Suspense, useState, type ReactNode } from "react";

import baseline from "../../../../benchmark/baseline.json";
import { Backdrop } from "../components/backdrop";
import { highlightFoo } from "../components/code";
import type { SceneKind } from "../components/technical-scene";

const SceneCanvas = lazy(() => import("../components/technical-scene").then(({ TechnicalScene }) => ({ default: TechnicalScene })));

type LandingProps = { onEnter: (query?: string) => void };

const examples = [
  { name: "First program", file: "main.iv", source: 'display "Hello, world!".', output: "Hello, world!" },
  { name: "Failure", file: "read.iv", source: 'use file.\n\nconstant content is file.read("notes.txt") try.\ndisplay content.', output: "A missing file propagates an error." },
  { name: "Values", file: "values.iv", source: 'constant name is "FOO".\nconstant message is "Hello, " plus name.\ndisplay message.', output: "Hello, FOO" },
] as const;

export default function Landing({ onEnter }: LandingProps) {
  const [example, setExample] = useState(0);
  const [copied, setCopied] = useState(false);
  const current = examples[example];

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(current.source);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1800);
    } catch {
      setCopied(false);
    }
  };

  return <div className="landing-page registry-home h-dvh overflow-x-hidden overflow-y-auto bg-[#080808] text-[#f5f5f5] selection:bg-[#60D5DF] selection:text-black">
    <Backdrop />
    <header className="landing-site-header sticky top-0 z-30 flex items-center justify-between px-5 sm:px-8">
      <a className="registry-home-brand" href="/" aria-label="FOO home"><img src="/icon.svg" alt="" /><strong>FOO</strong><span>LANGUAGE</span></a>
      <nav className="registry-home-nav" aria-label="Primary navigation">
        <a href="/standard" title="Standard library" aria-label="Standard library"><Braces size={15} /><span>Standard</span></a>
        <a href="/docs/overview" title="Documentation" aria-label="Documentation"><BookOpen size={15} /><span>Docs</span></a>
        <a href="/downloads" title="Downloads" aria-label="Downloads"><Download size={15} /><span>Downloads</span></a>
        <a className="registry-home-source" href="https://github.com/radiiplus/foo" target="_blank" rel="noreferrer" title="FOO source repository" aria-label="FOO source repository"><GitFork size={15} /></a>
      </nav>
    </header>

    <main className="registry-home-main foo3d-landing">
      <section className="foo3d-hero" aria-labelledby="registry-home-title">
        <div className="foo3d-hero-copy"><p className="registry-kicker">NATIVE SYSTEMS / READABLE BY DESIGN</p><h1 id="registry-home-title">FOO</h1><p className="foo3d-hero-hook">Let the code read. Let the machine run.</p><p>A systems language with explicit failure and ownership, C and Zig backends, and one toolchain from first file to published package.</p><div className="registry-home-hero-actions"><a className="primary" href="/docs/start">Start building <ArrowRight size={16} /></a><a href="#why-foo">Explore FOO <ArrowRight size={15} /></a><a href="https://github.com/radiiplus/foo" target="_blank" rel="noreferrer">View source <GitFork size={15} /></a></div></div>
        <Scene kind="hero" label="Interactive 3D representation of FOO source, checking, and native output" className="foo3d-hero-scene" />
      </section>

      <Story id="why-foo" number="01" topic="THE IDEA" title="Who pays for the abstraction?" kind="thesis" label="Three 3D layers connecting readable source, checked semantics, and native output">
        <p>FOO's sentence-like syntax has exact, checkable meaning. Types, errors, storage, and low-level access remain visible where they matter, so an expressive program can still be inspected as systems code.</p>
        <a className="foo3d-link" href="/docs/foundations">Read the design foundations <ArrowRight size={15} /></a>
      </Story>

      <Story id="performance" number="02" topic="EVIDENCE" title="Where did 116 milliseconds go?" kind="performance" label="3D representation of packed operations replacing repeated per-bit work" reverse>
        <p>On one packed bitmap fixture, replacing per-bit work with packed-word operations cut the C backend's median operation time from {baseline.operationMedianMs.control.toFixed(2)} ms to {baseline.operationMedianMs.foo.toFixed(2)} ms: 83.2x on this fixture.</p>
        <div className="foo3d-measure"><span><b>{baseline.operationMedianMs.control.toFixed(2)} ms</b> before</span><i /><span><b>{baseline.operationMedianMs.foo.toFixed(2)} ms</b> after</span></div>
        <p className="foo3d-fineprint">30,000 64-bit words per input; Windows x64, Intel Core i5-1145G7. A separate C++20 control was faster. These are workload results, not a language ranking.</p>
        <a className="foo3d-link" href="/docs/audit">Inspect the paired audit <ArrowRight size={15} /></a>
      </Story>

      <Story id="language" number="03" topic="SOURCE" title="Can a whole program fit on one line?" kind="language" label="3D stack of source tokens and typed operations">
        <p>It can. The same grammar extends to named values, functions, and explicit failure handling. Switch between these real FOO snippets and copy the source.</p>
        <div className="foo3d-code-tool">
          <div className="foo3d-code-head"><div role="tablist" aria-label="FOO code examples">{examples.map((item, index) => <button type="button" role="tab" aria-selected={example === index} className={example === index ? "active" : ""} key={item.file} onClick={() => { setExample(index); setCopied(false); }}>{item.name}</button>)}</div><button type="button" onClick={() => void copy()} title={copied ? "Copied" : "Copy source"} aria-label={copied ? "Copied source" : "Copy source"}>{copied ? <Check size={14} /> : <Copy size={14} />}</button></div>
          <pre role="tabpanel" aria-label={current.file}><code>{current.source.split("\n").map((line, index) => <span className="foo3d-code-line" key={`${example}-${index}`}><span>{String(index + 1).padStart(2, "0")}</span><span dangerouslySetInnerHTML={{ __html: highlightFoo(line) || " " }} /></span>)}</code></pre>
          <div className="foo3d-code-result"><span>{current.file}</span><strong>{current.output}</strong></div>
        </div>
        <a className="foo3d-link" href="/docs/introduction">Start with the language <ArrowRight size={15} /></a>
      </Story>

      <Story id="compiler" number="04" topic="COMPILER" title="What survives the trip to native?" kind="compiler" label="Five connected 3D compiler stages, branching into native C and Zig output" reverse>
        <p>FOO parses and checks source, lowers it to an intermediate representation, specializes the work, then emits C or Zig. Reachability keeps only the functions and runtime services the output needs.</p>
        <div className="foo3d-inline-steps"><span>SOURCE</span><i /><span>CHECK</span><i /><span>IR</span><i /><span>C / ZIG</span></div>
        <a className="foo3d-link" href="/docs/compiler">Follow the compiler <ArrowRight size={15} /></a>
      </Story>

      <Story id="memory" number="05" topic="MEMORY" title="Who lets go of the bytes?" kind="memory" label="Nested 3D lifetime rings with a moving owned value">
        <p>Scoped regions, explicit allocators, borrowed views, and <code>after</code> cleanup give storage a visible lifetime. FOO does not use a tracing garbage collector; ownership and release stay part of the program's contract.</p>
        <a className="foo3d-link" href="/docs/memory">Trace a value's lifetime <ArrowRight size={15} /></a>
      </Story>

      <Story id="systems" number="06" topic="SYSTEMS" title="How far down can the same language go?" kind="systems" label="Interactive 3D network connecting FOO's systems library capabilities" reverse>
        <p>From collections and files to processes, sockets, tasks, atomics, CPU vectors, and Vulkan compute, the standard library exposes both ordinary APIs and explicit hardware-aware paths.</p>
        <p className="foo3d-fineprint">Target support and GPU benefit depend on the workload and available hardware.</p>
        <a className="foo3d-link" href="/standard">Explore the standard library <ArrowRight size={15} /></a>
      </Story>

      <Story id="workflow" number="07" topic="TOOLCHAIN" title="What happens after hello world?" kind="workflow" label="Five linked 3D stages representing project creation, running, testing, building, and publishing">
        <p><code>foo new</code> creates source, test, and benchmark roots. The same CLI runs, tests, measures, builds, and locks dependencies as the project grows.</p>
        <div className="foo3d-commands"><code>foo new hello</code><code>foo run</code><code>foo test</code><code>foo benchmark</code></div>
        <div className="foo3d-story-actions"><a className="foo3d-link" href="/docs/projects">See the project model <ArrowRight size={15} /></a><button type="button" className="foo3d-link" onClick={() => onEnter()}>Browse packages <PackageSearch size={15} /></button></div>
      </Story>

      <section className="foo3d-closing" aria-labelledby="foo-closing-title"><p className="registry-kicker">INSPECT / BUILD / MEASURE</p><h2 id="foo-closing-title">Don't take it on faith.</h2><p>Read the language. Run the code. Inspect the compiler and measurements. Then decide what FOO can do for your project.</p><div className="foo3d-closing-actions"><a href="/docs/start">Get started <ArrowRight size={15} /></a><a href="/docs/benchmarking">Benchmarking <ArrowRight size={15} /></a><a href="https://github.com/radiiplus/foo" target="_blank" rel="noreferrer">Source <GitFork size={15} /></a><a href="/downloads">Downloads <Download size={15} /></a></div></section>
    </main>
    <footer className="foo-landing-footer"><span>FOO / LANGUAGE / TOOLCHAIN / REGISTRY</span><div><a href="/docs/status">Feature status</a><a href="/docs/overview">Documentation</a><a href="/registry">Packages</a></div></footer>
  </div>;
}

function Story({ id, number, topic, title, kind, label, reverse, children }: {
  id: string; number: string; topic: string; title: string; kind: SceneKind; label: string; reverse?: boolean; children: ReactNode;
}) {
  return <section id={id} className={`foo3d-story${reverse ? " reverse" : ""}`} aria-labelledby={`${id}-title`}>
    <div className="foo3d-story-copy"><p className="registry-kicker">{number} / {topic}</p><h2 id={`${id}-title`}>{title}</h2>{children}</div>
    <Scene kind={kind} label={label} />
  </section>;
}

function Scene({ kind, label, className = "" }: { kind: SceneKind; label: string; className?: string }) {
  return <Suspense fallback={<div className={`foo3d-scene ${className}`} aria-hidden="true" />}><SceneCanvas kind={kind} label={label} className={className} /></Suspense>;
}
