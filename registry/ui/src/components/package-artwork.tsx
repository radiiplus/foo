import {
  Activity, Archive, Atom, Binary, Boxes, Braces, CalendarDays, Clock3, Code2, Cpu, Database, FileText,
  FolderOpen, GitBranch, Globe, Hash, Layers3, List, LockKeyhole, MemoryStick, Network,
  PackageCheck, ShieldCheck, Terminal, type LucideIcon,
} from "lucide-react";

import { Icon } from "./icon";

const modules: Array<[LucideIcon, Set<string>]> = [
  [Network, new Set("adapter dns http ipc net tls".split(" "))],
  [Cpu, new Set("arch cpu gpu simd topology vulkan".split(" "))],
  [Atom, new Set("atomic thread task".split(" "))],
  [Binary, new Set("base64 binary bitmap block buffer codec frame hex packing radix zigzag".split(" "))],
  [Hash, new Set("blake bloom checksum".split(" "))],
  [FolderOpen, new Set("dylib file io virtual".split(" "))],
  [List, new Set("iterator list queue ring sequence set stack stream".split(" "))],
  [Database, new Set("heap map table transaction tree".split(" "))],
  [MemoryStick, new Set("memory".split(" "))],
  [CalendarDays, new Set("calendar time timer".split(" "))],
  [Clock3, new Set("poll".split(" "))],
  [Activity, new Set("limit metric trace".split(" "))],
  [ShieldCheck, new Set("contract issue testing".split(" "))],
  [Layers3, new Set("matrix tensor".split(" "))],
  [Globe, new Set("platform unicode units".split(" "))],
  [FileText, new Set("json log text".split(" "))],
  [Code2, new Set("state".split(" "))],
  [Archive, new Set("compress".split(" "))],
  [GitBranch, new Set("route".split(" "))],
  [LockKeyhole, new Set("crypto".split(" "))],
  [Terminal, new Set("process system".split(" "))],
  [PackageCheck, new Set("resource".split(" "))],
];

export function PackageArtwork({ name, kind, icon, size = 18 }: {
  name: string;
  kind: "package" | "standard";
  icon?: string;
  size?: number;
}) {
  const moduleName = name.startsWith("lib/") ? name.slice(4) : name;
  const Fallback = kind === "standard"
    ? modules.find(([, names]) => names.has(moduleName))?.[0] ?? Braces
    : Boxes;
  return <Icon svg={icon}><Fallback size={size} /></Icon>;
}
