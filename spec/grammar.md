# Arc Grammar v1

Program     ::= Module*
Module      ::= "module" IDENT Body
Body        ::= "<" Stmt* ">"

Decl        ::= "pub"? ( LetDecl | VarDecl | FnDecl | TypeDecl | UseDecl )
LetDecl     ::= "let" IDENT ( ":" Type )? "becomes" Expr
VarDecl     ::= "var" IDENT ( ":" Type )? "becomes" Expr
FnDecl      ::= IDENT ParamList? ( "where" Constraint )? Body
TypeDecl    ::= "type" IDENT "becomes" TypeDef
UseDecl     ::= "use" IDENT

Stmt        ::= LetDecl | VarDecl | GiveStmt | WhenStmt | WhileStmt | ForStmt
              | MatchStmt | BreakStmt | ContinueStmt | TryStmt | DeferStmt
              | UnsafeStmt | ActionStmt
GiveStmt    ::= "give" Expr?
WhenStmt    ::= "when" Expr Body ( "otherwise" ( Body | WhenStmt ) )?
WhileStmt   ::= "while" Expr Body
ForStmt     ::= "for" "each" IDENT "in" Expr Body
MatchStmt   ::= "match" Expr Body
BreakStmt   ::= "break"
ContinueStmt ::= "continue"
TryStmt     ::= "try" Expr
DeferStmt   ::= "on" "leave" ( Expr | Body )
UnsafeStmt  ::= "unsafe" Body
ActionStmt  ::= IDENT Expr*

Expr        ::= BinaryExpr | UnaryExpr | PostfixExpr | Literal | IDENT | GroupExpr
BinaryExpr  ::= Expr BinOp Expr
BinOp       ::= "plus" | "minus" | "times" | "divided" "by"
              | "equals" | "does" "not" "equal"
              | "is" "greater" "than" | "is" "less" "than"
              | "is" "at" "least" | "is" "at" "most"
              | "and" | "or" | "catch"
UnaryExpr   ::= "not" Expr
PostfixExpr ::= CallExpr | FieldExpr | IndexExpr
CallExpr    ::= Expr "(" ArgList? ")"
FieldExpr   ::= Expr "." IDENT
IndexExpr   ::= Expr "[" Expr "]"
GroupExpr   ::= "(" Expr ")"

Literal     ::= NUMBER | STRING | "true" | "false" | "uninit" | "unreachable" | Quantity
Quantity    ::= NUMBER Unit
Unit        ::= "bytes" | "bits" | "kilobytes" | "megabytes" | "gigabytes" | "terabytes"
              | "seconds" | "milliseconds" | "microseconds" | "nanoseconds"

Type        ::= PrimType | ArrayType | SequenceType | OptionalType | ErrorType | NamedType
PrimType    ::= "integer" NUMBER? | "unsigned" NUMBER? | "decimal" NUMBER?
              | "boolean" | "byte" | "character" | "text" | "nothing"
ArrayType   ::= "array" "of" Type
SequenceType ::= "sequence" "of" Type
OptionalType ::= "?" Type
ErrorType   ::= "!" Type | Type "or" "Error"
NamedType   ::= IDENT

Pattern     ::= IDENT | "_" | Literal
ParamList   ::= Param ( "," Param )*
Param       ::= IDENT ":" Type
Constraint  ::= IDENT "is" IDENT
TypeDef     ::= StructDef | EnumDef | Type
StructDef   ::= "record" Body
EnumDef     ::= "choice" Body