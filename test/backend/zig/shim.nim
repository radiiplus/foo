import std/strutils
import ../../../src/backend/zig/shim as zigShim

doAssert len(zigShim.`shim`) > 0 and zigShim.`shim`[0] == '\n'
doAssert zigShim.`shim`.contains("foo_")
doAssert zigShim.`shim`.contains("library.memory.copyExact")
doAssert zigShim.storage.contains("pub fn copyExact")
doAssert zigShim.storage.contains("FOO_TRANSFER_BLOCK")
doAssert zigShim.library.contains("fn hashmap")
doAssert zigShim.library.contains("fn cloneBytes")
doAssert zigShim.library.contains("pub const io = struct")
doAssert zigShim.library.contains("runtimeIo()")
echo "Zig shim parity: ok"
