import { AlertTriangle, Archive, CheckCircle2, Download, ExternalLink, Laptop, Package, Terminal, type LucideIcon } from "lucide-react";
import { useEffect, useMemo, useState } from "react";

type GitHubAsset = {
  name: string;
  browser_download_url: string;
};

type GitHubRelease = {
  tag_name: string;
  html_url: string;
  assets: GitHubAsset[];
  published_at?: string;
  draft?: boolean;
  prerelease?: boolean;
};

type AssetDefinition = {
  label: string;
  icon: LucideIcon;
  matches: (name: string) => boolean;
};

type Platform = {
  name: string;
  detail: string;
  note: string;
  warning?: string;
  assets: AssetDefinition[];
};

const compilerRelease = /^foo-v\d/;
const refreshInterval = 15 * 60 * 1_000;
const fallbackTag = "foo-v0.2.1";
const fallbackBase = `https://github.com/radiiplus/foo/releases/download/${fallbackTag}`;
const fallbackRelease: GitHubRelease = {
  tag_name: fallbackTag,
  html_url: `https://github.com/radiiplus/foo/releases/tag/${fallbackTag}`,
  assets: [
    "foo-0.2.1.tgz",
    "foo-amd64.deb",
    "foo-arm64.deb",
    "foo-linux-x64.tar.gz",
    "foo-linux-arm64.tar.gz",
    "foo-windows-x64.exe",
    "foo-windows-x64.zip",
    "SHA256SUMS.txt",
  ].map((name) => ({ name, browser_download_url: `${fallbackBase}/${name}` })),
};
const isWindows = (name: string) => name.includes("windows-x64");
const isLinuxX64 = (name: string) => name.includes("linux-x64") || name.includes("amd64");
const isLinuxArm64 = (name: string) => name.includes("linux-arm64") || name.includes("arm64");

const platforms: Platform[] = [
  {
    name: "Windows x64",
    detail: "Windows 10 or newer",
    note: "Use the installer for normal setup or the ZIP for a portable toolchain.",
    warning: "Code signing is pending. Windows may temporarily show Unknown publisher; verify the SHA-256 checksum before running the download.",
    assets: [
      { label: "Installer", icon: Download, matches: (name) => isWindows(name) && name.endsWith(".exe") },
      { label: "Portable ZIP", icon: Archive, matches: (name) => isWindows(name) && name.endsWith(".zip") },
    ],
  },
  {
    name: "Linux x64",
    detail: "Ubuntu and Debian, amd64",
    note: "The Debian package installs the foo command system-wide.",
    assets: [
      { label: "Debian package", icon: Package, matches: (name) => isLinuxX64(name) && name.endsWith(".deb") },
      { label: "Tar archive", icon: Archive, matches: (name) => isLinuxX64(name) && name.endsWith(".tar.gz") },
    ],
  },
  {
    name: "Linux ARM64",
    detail: "Ubuntu ARM64, including Termux/proot",
    note: "Run this inside the Ubuntu environment. It targets glibc, not Android directly.",
    assets: [
      { label: "Debian package", icon: Package, matches: (name) => isLinuxArm64(name) && name.endsWith(".deb") },
      { label: "Tar archive", icon: Archive, matches: (name) => isLinuxArm64(name) && name.endsWith(".tar.gz") },
    ],
  },
];

export default function Downloads() {
  const [release, setRelease] = useState<GitHubRelease>();
  const [error, setError] = useState(false);

  useEffect(() => {
    const controller = new AbortController();
    const loadRelease = () => {
      void fetch("https://api.github.com/repos/radiiplus/foo/releases?per_page=100", {
        cache: "no-store",
        headers: { Accept: "application/vnd.github+json" },
        signal: controller.signal,
      })
        .then(async (response) => {
          if (!response.ok) throw new Error("Release catalog unavailable");
          const releases = await response.json() as GitHubRelease[];
          const current = releases
            .filter((candidate) => compilerRelease.test(candidate.tag_name) && !candidate.draft && !candidate.prerelease)
            .sort((left, right) => Date.parse(right.published_at ?? "") - Date.parse(left.published_at ?? ""))[0];
          if (!current) throw new Error("No compiler release found");
          setRelease(current);
          setError(false);
        })
        .catch((reason: unknown) => {
          if (!(reason instanceof DOMException && reason.name === "AbortError")) {
            setRelease((current) => current ?? fallbackRelease);
            setError(true);
          }
        });
    };
    const onFocus = () => loadRelease();
    loadRelease();
    const interval = window.setInterval(loadRelease, refreshInterval);
    window.addEventListener("focus", onFocus);
    return () => {
      controller.abort();
      window.clearInterval(interval);
      window.removeEventListener("focus", onFocus);
    };
  }, []);

  const version = release?.tag_name.replace(/^foo-v/, "");
  const assets = useMemo(() => release?.assets ?? [], [release]);
  const npmAsset = assets.find((asset) => /^foo-\d.+\.tgz$/.test(asset.name));
  const checksums = assets.find((asset) => asset.name === "SHA256SUMS.txt");

  return (
    <div className="min-h-full bg-[#080808]">
      <div className="mx-auto flex min-h-full w-full max-w-5xl flex-col px-5 py-5 sm:px-8 sm:py-6">
        <header className="border-b border-[#292929] pb-4">
          <div className="mb-2 flex items-center gap-2 font-mono text-[9px] tracking-[0.14em] text-[#60D5DF] uppercase">
            {error ? "Release service unavailable" : "Stable release"}
          </div>
          <div className="flex flex-col justify-between gap-3 sm:flex-row sm:items-end">
            <div>
              <h1 className="text-2xl font-semibold tracking-normal text-[#f5f5f5] sm:text-3xl">Download FOO</h1>
              <p className="mt-2 max-w-xl text-xs leading-5 text-[#858585]">Native installers and portable archives from the latest published compiler release.</p>
            </div>
            <div className="flex shrink-0 flex-wrap gap-x-4 gap-y-1 font-mono text-[9px] text-[#666] sm:block sm:text-right">
              <div>PUBLISHED <span className="ml-2 text-[#d8d8d8]">{version ?? (error ? "UNAVAILABLE" : "CHECKING")}</span></div>
            </div>
          </div>
        </header>

        <section className="divide-y divide-[#262626]" aria-label="Platform downloads">
          {platforms.map((platform) => {
            const available = platform.assets.flatMap((definition) => {
              const asset = assets.find((candidate) => definition.matches(candidate.name.toLowerCase()));
              return asset ? [{ ...definition, asset }] : [];
            });
            return (
              <div key={platform.name} className="grid gap-3 py-4 md:grid-cols-[minmax(0,1fr)_auto] md:items-center">
                <div className="flex min-w-0 gap-3">
                  <span className="grid size-9 shrink-0 place-items-center rounded-md border border-[#2b2b2b] bg-[#111] text-[#a8a8a8]">
                    <Laptop size={16} />
                  </span>
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <h2 className="text-sm font-semibold text-[#ededed]">{platform.name}</h2>
                      {platform.name === "Windows x64" && <span className="rounded border border-[#285A5E] bg-[#102124] px-1.5 py-0.5 font-mono text-[8px] text-[#60D5DF] uppercase">Recommended</span>}
                    </div>
                    <p className="mt-1 text-[11px] leading-4 text-[#707070]">{platform.detail}</p>
                    <p className="mt-1 max-w-xl text-[11px] leading-4 text-[#929292]">{platform.note}</p>
                    {platform.warning && (
                      <p className="mt-1.5 flex max-w-xl items-start gap-1.5 text-[10px] leading-4 text-[#c8ad73]" role="note">
                        <AlertTriangle className="mt-0.5 shrink-0" size={11} />
                        <span>{platform.warning}</span>
                      </p>
                    )}
                  </div>
                </div>
                <div className="flex flex-wrap gap-2 md:justify-end">
                  {available.map(({ label, icon: Icon, asset }) => (
                    <a key={asset.name} className="inline-flex h-8 items-center gap-2 rounded-md border border-[#303030] bg-[#111] px-3 text-[11px] text-[#cfcfcf] no-underline hover:border-[#596a25] hover:bg-[#14170e] hover:text-white" href={asset.browser_download_url}>
                      <Icon size={13} className="text-[#60D5DF]" /> {label}
                    </a>
                  ))}
                  {release && available.length === 0 && <span className="flex h-8 items-center font-mono text-[9px] text-[#555]">Not included in {release.tag_name}</span>}
                  {!release && !error && <span className="flex h-8 items-center font-mono text-[9px] text-[#555]">Checking assets...</span>}
                </div>
              </div>
            );
          })}
        </section>

        <section className="mt-3 border-t border-[#292929] pt-3">
          <h2 className="text-sm font-semibold text-[#ededed]">Release files</h2>
          <div className="mt-2 grid gap-px overflow-hidden rounded-md border border-[#292929] bg-[#292929] sm:grid-cols-3">
            <ReleaseFile asset={npmAsset} icon={Terminal} title="npm package" />
            <ReleaseFile asset={checksums} icon={CheckCircle2} title="SHA-256 checksums" />
            <a className="flex min-h-14 items-center gap-3 bg-[#0e0e0e] px-4 text-[#aaa] no-underline hover:bg-[#131313] hover:text-white" href={release?.html_url ?? "https://github.com/radiiplus/foo/releases"} target="_blank" rel="noreferrer">
              <ExternalLink size={15} className="text-[#60D5DF]" /><span><strong className="block text-xs font-medium">Release notes</strong><small className="mt-1 block font-mono text-[9px] text-[#5f5f5f]">GitHub release</small></span>
            </a>
          </div>
        </section>
      </div>
    </div>
  );
}

function ReleaseFile({ asset, icon: Icon, title }: { asset?: GitHubAsset; icon: LucideIcon; title: string }) {
  if (!asset) {
    return (
      <span className="flex min-h-14 items-center gap-3 bg-[#0e0e0e] px-4 text-[#555]">
        <Icon size={15} /><span><strong className="block text-xs font-medium">{title}</strong><small className="mt-1 block font-mono text-[9px]">Not available</small></span>
      </span>
    );
  }
  return (
    <a className="flex min-h-14 items-center gap-3 bg-[#0e0e0e] px-4 text-[#aaa] no-underline hover:bg-[#131313] hover:text-white" href={asset.browser_download_url}>
      <Icon size={15} className="text-[#60D5DF]" /><span><strong className="block text-xs font-medium">{title}</strong><small className="mt-1 block font-mono text-[9px] text-[#5f5f5f]">{asset.name}</small></span>
    </a>
  );
}
