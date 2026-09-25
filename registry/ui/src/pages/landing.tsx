import { ArrowRight, BookOpen, Braces, Download, GitFork, PackageSearch, ShieldCheck, Terminal } from "lucide-react";

type LandingProps = {
  onEnter: () => void;
};

export default function Landing({ onEnter }: LandingProps) {
  return (
    <div className="flex h-dvh flex-col overflow-hidden bg-[#080808] text-[#f5f5f5]">
      <header className="flex h-14 items-center justify-between border-b border-[#222] px-5 sm:px-8">
        <a className="flex items-center gap-2.5" href="/" aria-label="Foo home">
          <img className="size-7" src="/icon.svg" alt="" />
          <span className="text-[11px] font-semibold tracking-[0.14em] text-[#777] uppercase">Foo</span>
        </a>
        <nav className="flex items-center gap-2">
          <a className="flex h-8 items-center gap-1.5 rounded-lg px-2.5 text-xs text-[#888] no-underline hover:bg-[#171717] hover:text-white" href="/standard">
            <Braces size={14} /> <span className="hidden sm:inline">Standard</span>
          </a>
          <a className="flex h-8 items-center gap-1.5 rounded-lg px-2.5 text-xs text-[#888] no-underline hover:bg-[#171717] hover:text-white" href="/downloads">
            <Download size={14} /> <span className="hidden sm:inline">Downloads</span>
          </a>
          <a className="flex h-8 items-center gap-1.5 rounded-lg px-2.5 text-xs text-[#888] no-underline hover:bg-[#171717] hover:text-white" href="/docs/overview">
            <BookOpen size={14} /> Docs
          </a>
          <a className="grid size-8 place-items-center rounded-lg text-[#777] hover:bg-[#171717] hover:text-white" href="https://github.com/radiiplus/foo" target="_blank" rel="noreferrer" title="Open source repository">
            <GitFork size={15} />
          </a>
          <button className="flex h-8 items-center gap-2 rounded-lg bg-[#60D5DF] px-3 text-xs font-semibold text-[#0a0a0a] hover:bg-[#82E3EB]" type="button" onClick={onEnter}>
            Libraries <ArrowRight size={13} />
          </button>
        </nav>
      </header>

      <main className="flex min-h-0 flex-1 flex-col">
        <section className="landing-hero mx-auto flex min-h-0 w-full max-w-300 flex-1 flex-col justify-center overflow-hidden px-5 py-6 sm:px-8 sm:py-8">
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
            <img className="mb-5 size-14 sm:mb-6 sm:size-18" src="/icon.svg" alt="Foo" />
            <p className="mb-4 font-mono text-[10px] tracking-[0.18em] text-[#60D5DF] uppercase">Native systems, readable by design</p>
            <h1 className="max-w-220 text-4xl leading-[0.92] font-semibold tracking-normal text-[#f5f5f5] sm:text-6xl lg:text-7xl">
              FOO
            </h1>
            <p className="mt-4 max-w-150 text-sm leading-6 text-[#898989] sm:text-base">
              A sentence-like systems language with native performance, explicit safety, and a package ecosystem built into the toolchain.
            </p>
            <div className="landing-hero-actions mt-6 flex flex-wrap items-center gap-3">
              <button className="flex h-10 items-center gap-2 rounded-lg bg-[#60D5DF] px-4 text-sm font-semibold text-[#080808] hover:bg-[#82E3EB]" type="button" onClick={onEnter}>
                Explore packages <PackageSearch size={15} />
              </button>
              <a className="flex h-10 items-center gap-2 rounded-lg border border-[#303030] bg-[#111] px-4 text-sm text-[#aaa] no-underline hover:border-[#444] hover:text-white" href="https://github.com/radiiplus/foo" target="_blank" rel="noreferrer">
                View source <GitFork size={14} />
              </a>
              <a className="flex h-10 items-center gap-2 rounded-lg border border-[#303030] bg-[#111] px-4 text-sm text-[#aaa] no-underline hover:border-[#444] hover:text-white" href="/downloads">
                Download <Download size={14} />
              </a>
              <a className="grid size-10 place-items-center rounded-lg border border-[#303030] bg-[#111] text-[#aaa] no-underline hover:border-[#444] hover:text-white" href="/docs/overview" title="Read documentation">
                <BookOpen size={15} />
              </a>
            </div>
          </div>
        </section>

        <section className="border-y border-[#222] bg-[#0b0b0b]">
          <div className="mx-auto grid h-20 max-w-300 grid-cols-3 divide-x divide-[#222] px-3 sm:h-24 sm:px-8">
            <div className="flex items-center gap-2 px-2 sm:gap-3 sm:px-5"><Terminal size={15} className="shrink-0 text-[#60D5DF]" /><div><p className="text-[10px] text-[#d8d8d8] sm:text-xs">One toolchain</p><p className="mt-1 text-[9px] text-[#5f5f5f] max-sm:hidden">Build, test, publish</p></div></div>
            <div className="flex items-center gap-2 px-2 sm:gap-3 sm:px-5"><ShieldCheck size={15} className="shrink-0 text-[#60D5DF]" /><div><p className="text-[10px] text-[#d8d8d8] sm:text-xs">Exact resolution</p><p className="mt-1 text-[9px] text-[#5f5f5f] max-sm:hidden">Reproducible by default</p></div></div>
            <div className="flex items-center gap-2 px-2 sm:gap-3 sm:px-5"><PackageSearch size={15} className="shrink-0 text-[#60D5DF]" /><div><p className="text-[10px] text-[#d8d8d8] sm:text-xs">Open registry</p><p className="mt-1 text-[9px] text-[#5f5f5f] max-sm:hidden">Git-backed packages</p></div></div>
          </div>
        </section>
      </main>
    </div>
  );
}
