## Token kinds used by the FOO lexer and parser.
type
  Kind* = enum
    Int, Float, String, Char, Ident,
    Constant, Mutable, Is, Are, Give, When, Otherwise,
    For, Each, In, While,
    Match, Case, Break, Continue, Use, Public, Unsafe,
    Native, Try, Catch, And, Or, Not,
    Where, Of, Type, Plus, Minus, Times, Divided, By,
    Equal, Greater, Than, Less, At, Least, Most, Integer,
    Unsigned, Decimal, Boolean, Byte, Character, Text,
    Sequence, Nothing, Null, Record, Choice, Function, True, False,
    Uninitialized, Unreachable, Optional, Pointer, To,
    Start, Newline, Anything, Test, Eval,
    Reflect, Embed, Open, Shut, Paren, Close, Square, Bracket, Dot, Comma,
    Colon, HashBracket, NewlineToken, Eof, Broken, Derives, Packed, Union,
    Opaque, Vector, After
