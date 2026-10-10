import { AlertTriangle, Archive, CheckCircle2, Download, ExternalLink, Laptop, Package, Puzzle, Terminal, type LucideIcon } from "lucide-react";
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
const fallbackTag = "foo-v0.7.1";
const fallbackBase = `https://github.com/radiiplus/foo/releases/download/${fallbackTag}`;
const fallbackRelease: GitHubRelease = {
  tag_name: fallbackTag,
  html_url: `https://github.com/radiiplus/foo/releases/tag/${fallbackTag}`,
  assets: [
    "foo-0.7.1.tgz",
    "foo-amd64.deb",
    "foo-arm64.deb",
    "foo-linux-x64.tar.gz",
    "foo-linux-arm64.tar.gz",
    "foo-windows-x64.exe",
    "foo-windows-x64.zip",
    "foo.iv-2.6.2.vsix",
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
    note: "Use the installer for normal setup. Remove FOO later from Windows Installed Apps or its Start Menu shortcut.",
    warning: "Code signing is pending. Windows may temporarily show Unknown publisher; verify the SHA-256 checksum before running the download.",
    assets: [
      { label: "Installer", icon: Download, matches: (name) => isWindows(name) && name.endsWith(".exe") },
      { label: "Portable ZIP", icon: Archive, matches: (name) => isWindows(name) && name.endsWith(".zip") },
    ],
  },
  {
    name: "Linux x64",
    detail: "Ubuntu and Debian, amd64",
    note: "The Debian package installs system-wide. Remove it and its managed backend with sudo apt remove foo.",
    assets: [
      { label: "Debian package", icon: Package, matches: (name) => isLinuxX64(name) && name.endsWith(".deb") },
      { label: "Tar archive", icon: Archive, matches: (name) => isLinuxX64(name) && name.endsWith(".tar.gz") },
    ],
  },
  {
    name: "Linux ARM64",
    detail: "Ubuntu ARM64, including Termux/proot",
    note: "Run this inside Ubuntu, not Android directly. Remove it later with sudo apt remove foo.",
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
  const extension = assets.find((asset) => asset.name.endsWith(".vsix"));
  const checksums = assets.find((asset) => asset.name === "SHA256SUMS.txt");

  return (
    <div className="registry-downloads">
      <header className="registry-downloads-head">
        <div><p className="registry-kicker">{error ? "Release service unavailable" : "Stable release"}</p><h1>Download FOO</h1><p>Native installers and portable archives from the latest published compiler release.</p></div>
        <span className="registry-download-version">{version ? `Version ${version}` : error ? "Release unavailable" : "Checking release"}</span>
      </header>

        <section className="registry-platform-grid" aria-label="Platform downloads">
          {platforms.map((platform) => {
            const available = platform.assets.flatMap((definition) => {
              const asset = assets.find((candidate) => definition.matches(candidate.name.toLowerCase()));
              return asset ? [{ ...definition, asset }] : [];
            });
            return (
              <article key={platform.name} className="registry-platform-card">
                <div className="registry-platform-identity"><span className="registry-result-icon"><Laptop size={17} /></span><div><h2>{platform.name}</h2><p>{platform.detail}</p></div>{platform.name === "Windows x64" && <span className="registry-platform-recommended">Recommended</span>}</div>
                <p className="registry-platform-note">{platform.note}</p>
                {platform.warning && <p className="registry-platform-warning" role="note"><AlertTriangle size={13} /><span>{platform.warning}</span></p>}
                <div className="registry-platform-actions">
                  {available.map(({ label, icon: Icon, asset }) => (
                    <a key={asset.name} href={asset.browser_download_url}><Icon size={14} />{label}<Download size={13} /></a>
                  ))}
                  {release && available.length === 0 && <span>Not included in {release.tag_name}</span>}
                  {!release && !error && <span>Checking assets...</span>}
                </div>
              </article>
            );
          })}
        </section>

        <section className="registry-download-extras">
          <h2>Release files</h2>
          <div className="registry-download-file-grid">
            <ReleaseFile asset={npmAsset} icon={Terminal} title="npm package" />
            <ReleaseFile asset={extension} icon={Puzzle} title="VS Code extension" />
            <ReleaseFile asset={checksums} icon={CheckCircle2} title="SHA-256 checksums" />
            <a className="registry-download-file" href={release?.html_url ?? "https://github.com/radiiplus/foo/releases"} target="_blank" rel="noreferrer"><ExternalLink size={16} /><span><strong>Release notes</strong><small>GitHub release</small></span></a>
          </div>
        </section>
    </div>
  );
}

function ReleaseFile({ asset, icon: Icon, title }: { asset?: GitHubAsset; icon: LucideIcon; title: string }) {
  if (!asset) {
    return (
      <span className="registry-download-file unavailable">
        <Icon size={16} /><span><strong>{title}</strong><small>Not available</small></span>
      </span>
    );
  }
  return (
    <a className="registry-download-file" href={asset.browser_download_url}>
      <Icon size={16} /><span><strong>{title}</strong><small>{asset.name}</small></span>
    </a>
  );
}
