import ../targets/presets

type TaskBackend* = enum
  tbEpoll = "epoll", tbKqueue = "kqueue", tbIocp = "iocp", tbThreaded = "threaded"

proc taskBackend*(os: string): TaskBackend =
  if os == "linux": tbEpoll
  elif os in ["macos", "ios", "freebsd", "openbsd", "netbsd"]: tbKqueue
  elif os == "windows": tbIocp
  else: tbThreaded

proc taskBackend*(target: Target): TaskBackend = taskBackend(target.os)
proc taskBackendForTarget*(target: Target): TaskBackend = taskBackend(target)
