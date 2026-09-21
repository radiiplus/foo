import std/os
import ./cli/main as cli

when isMainModule:
  quit(cli.main(commandLineParams()))
