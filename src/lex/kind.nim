## Token kinds used by the FOO lexer and parser.
type
  Kind* = enum
    Int, Float, String, Char, Ident,
    Module, Constant, Mutable, Is, Give, When, Otherwise,
    For, Each, In, While, Repeat, Until, Reaches, Advance,
    Match, Case, Break, Continue, Use, Public, Unsafe,
    Native, Evaluate, On, Leave, Try, Catch, And, Or, Not,
    Where, Of, Type, Plus, Minus, Times, Divided, By, Equals, Does,
    Equal, Greater, Than, Less, At, Least, Most, Integer,
    Unsigned, Decimal, Boolean, Byte, Character, Text, Array,
    Sequence, Nothing, Record, Choice, Function, True, False,
    Uninitialized, Unreachable, Optional, Pointer, To, Address,
    Reference, Start, Newline, Anything, Test, Context, Eval,
    Reflect, Embed, Open, Shut, Paren, Close, Square, Bracket, Dot, Comma,
    Colon, HashBracket, NewlineToken, Eof, Broken, Derives, Packed, Union,
    Opaque, Vector, NativeZig, Asm, After
