include "../../../src/backend/asm/emitter.nim"

doAssert emit("mov %0, %1", "x86_64", @["rax"]) == "__asm__ __volatile__(\"mov %%0, %%1\" : : : \"memory\", \"cc\", \"rax\");"
doAssert emit(".text", "aarch64", global = true) == "__asm__(\".text\");"
var rejected = false
try: discard emit("nop", "unknown")
except ValueError: rejected = true
doAssert rejected
echo "asm emitter parity: ok"
