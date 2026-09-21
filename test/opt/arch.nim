import ../../src/opt/arch

doAssert architecture("linux-x64") == "x86_64"
doAssert architecture("windows-arm64") == "aarch64"
doAssert profile("linux-x64", "x86_64_v3").vector == 256
doAssert profile("linux-arm64").cpu == "arm64"
var rejected = false
try: discard profile("linux-arm64", "x86-64-v3")
except ValueError: rejected = true
doAssert rejected
echo "architecture profile parity: ok"
