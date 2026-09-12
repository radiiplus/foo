export enum Code {
  // Lexer errors
  Unexpected,
  Unterminated,
  Invalid,
  InvalidEscape,
  Digit,
  // Parser errors
  Syntax,
  Missing,
  Extra,
  // Semantic errors
  Duplicate,
  Hidden,
  Clash,
  Absent,
  Circular,
  // Type errors
  TypeMismatch,
  NotCallable,
  NotIndexable,
  NotIterable,
  FieldNotFound,
  VariantNotFound,
  // Escape analysis
  ScopeEscape,
  // Resolution errors
  Undefined,
  NotExported,
  AlreadyImported,
  // Match errors
  NonExhaustive,
  UnreachableCase,
  // Backend errors
  BackendError,
  LinkError,
  // Package manager errors
  PkgConflict,
  PkgHashMismatch,
  PkgNotFound,
  // Error handling
  ErrorContext,
  UncaughtError,
  // Testing
  TestFailed,
}