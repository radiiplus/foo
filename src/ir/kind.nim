type
  Shape* = enum
    Int, Float, Bool, Ptr, Array, Struct, Void, Error, Vector, TaggedUnion,
    PackedStruct, ExternUnion, Opaque, Function, Uint, ExternStruct, Slice,
    Optional, Failable, Memory, Region, Trace

  Flavor* = enum
    Reg, Const, Global

  Opcode* = enum
    Alloc, Load, Store, Add, Sub, Mul, Div, Call, Jump, Cjump, Return, Panic,
    Try, Phi, Eval, Reflect, Embed, Splat, Shuffle, Gather, Scatter, Select, Reduce,
    Catch, Defer, Remainder, Compare, Not, Construct, Extract, Index, Length,
    Region, Allocate, Trace, Native, Atomic, Thread, Convert, Bit

const operations* = [
  "slot", "load", "store", "add", "subtract", "multiply", "divide", "call",
  "jump", "branch", "return", "panic", "result.value", "phi", "eval",
  "reflect", "embed", "vector.splat", "vector.shuffle", "vector.gather",
  "vector.scatter", "vector.select",
  "vector.reduce", "result.catch", "cleanup.register",
  "remainder", "compare", "not", "construct", "extract", "index", "length",
  "region", "allocate", "trace.append", "native", "atomic", "thread", "convert", "bit"
]
