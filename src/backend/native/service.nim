import std/[sets, strutils]
import ../../ir/node
import ../../build/options

const services* = ["bloom", "cpu", "topology", "platform", "dylib", "gpu", "vulkan", "io", "fs", "vm", "net", "tls", "process", "resource", "ring", "thread", "task", "time", "timer", "text", "metric", "trace", "limit"]

proc hosted*(module: Module; includeIo = true; includeTask = true): bool =
  for declaration in module.externs:
    let provider = if declaration.abi.startsWith("runtime."):
        declaration.abi[8 .. ^1] else: ""
    if (declaration.abi == "runtime" and includeTask) or
        (provider in services and (includeIo or provider != "io") and
          (includeTask or provider != "task")):
      return true
  false

proc resourceDefines*(module: Module): seq[string] =
  var providers = initHashSet[string]()
  for declaration in module.externs:
    if declaration.abi == "runtime": providers.incl("task")
    elif declaration.abi.startsWith("runtime."):
      providers.incl(declaration.abi[8 .. ^1])
  result.add("-DFOO_SERVICE_SELECTIVE")
  if "io" in providers or "fs" in providers:
    result.add("-DFOO_SERVICE_FS")
  if "net" in providers or "tls" in providers: result.add("-DFOO_SERVICE_NET")
  if "thread" in providers or "task" in providers:
    result.add("-DFOO_SERVICE_THREAD")
  if "task" in providers: result.add("-DFOO_SERVICE_TASK")
  if "gpu" in providers:
    result.add("-DFOO_SERVICE_GPU")
  if "gpu" in providers or "vulkan" in providers:
    result.add("-DFOO_SERVICE_VULKAN")
  if "cpu" in providers: result.add("-DFOO_SERVICE_CPU")

proc selective*(options: Native; native: bool): bool =
  options.kind notin ["static", "shared"] and options.sources.len == 0 and
    options.objects.len == 0 and options.libs.len == 0 and
    options.frameworks.len == 0 and not native

proc libraries*(target = ""): seq[string] =
  let platform = if target.len > 0: target
    elif defined(windows): "windows"
    elif defined(macosx): "macos"
    else: "linux"
  if platform.contains("windows") or platform.contains("win32"): @["ws2_32", "dnsapi", "iphlpapi"]
  elif platform.contains("macos") or platform.contains("darwin"): @["resolv"]
  else: @["pthread", "resolv", "dl"]
