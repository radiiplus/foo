import std/strutils
import ../../src/backend/zig/shim as zigShim

doAssert len(zigShim.`shim`) > 0 and zigShim.`shim`[0] == '\n'
doAssert zigShim.`shim`.contains("foo_")
echo "Zig shim parity: ok"
