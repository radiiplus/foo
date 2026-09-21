import ../../src/ir/kind

doAssert operations[ord(InstrKind.Alloc)] == "slot"
doAssert operations[ord(InstrKind.Convert)] == "convert"
doAssert ord(TypeKind.Trace) == 21
doAssert ord(ValueKind.Global) == 2
echo "ir kind parity: ok"
