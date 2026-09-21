import ../../src/build/options

doAssert artifact(Native(name: "demo", target: "windows-x64")) == "demo.exe"
doAssert artifact(Native(name: "demo", kind: "shared", target: "linux-x64", version: "1.2.3")) == "libdemo.so.1.2.3"
var rejected = false
try: validate(Native(name: "demo", kind: "exe", version: "1.0.0"))
except ValueError: rejected = true
doAssert rejected
echo "build options parity: ok"
