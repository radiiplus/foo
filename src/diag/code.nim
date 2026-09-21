type
  Code* = enum
    Unexpected, Unterminated, Invalid, InvalidEscape, Digit,
    Syntax, Missing, Extra, Duplicate, Hidden, Clash, Absent, Circular,
    TypeMismatch, NotCallable, NotIndexable, NotIterable, FieldNotFound,
    VariantNotFound, ScopeEscape, Undefined, NotExported, AlreadyImported,
    NonExhaustive, UnreachableCase, BackendError, LinkError, CBinding,
    NativePublic, PkgConflict, PkgHashMismatch, PkgNotFound, ErrorContext,
    UncaughtError, TestFailed
