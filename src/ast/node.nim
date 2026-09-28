import ../diag/span

type
  Node* = ref object of RootObj
    span*: Span
    tag*: string

  Declaration* = Node
  Statement* = Node
  Expression* = Node
  `Type`* = Node
  Pattern* = Node

  Program* = ref object of Node
    units*: seq[Unit]

  Unit* = ref object of Node
    name*: Name
    file*: string
    body*: Block

  Integer* = ref object of Node
    value*: string
  Decimal* = ref object of Node
    value*: string
  Text* = ref object of Node
    value*: string
  Character* = ref object of Node
    value*: string
  `True`* = ref object of Node
  `False`* = ref object of Node
  Nothing* = ref object of Node
  Null* = ref object of Node
  Uninitialized* = ref object of Node
  Unreachable* = ref object of Node
  NewlineExpr* = ref object of Node
  Name* = ref object of Node
    text*: string
  Call* = ref object of Node
    callee*: Expression
    args*: seq[Expression]
    names*: seq[string]
    types*: seq[`Type`]
    normalized*: bool
  Values* = ref object of Node
    items*: seq[Expression]
  Closure* = ref object of Node
    params*: seq[Parameter]
    returnType*: `Type`
    captures*: seq[Name]
    body*: Block
  Allocation* = ref object of Node
    size*: Expression
    owner*: Expression
  Assignment* = ref object of Node
    target*: Expression
    value*: Expression
  Machine* = ref object of Node
    operation*: string
    target*: Expression
    value*: Expression
    args*: seq[Expression]
    register*: string
  Unary* = ref object of Node
    op*: string
    operand*: Expression
  Binary* = ref object of Node
    op*: string
    left*: Expression
    right*: Expression
  Group* = ref object of Node
    expr*: Expression
  Field* = ref object of Node
    `object`*: Expression
    field*: Name
  Index* = ref object of Node
    `object`*: Expression
    index*: Expression

  TypeParam* = ref object of Node
    name*: Name
    bound*: Name
  GenericInst* = ref object of Node
    name*: Name
    args*: seq[`Type`]
  EvalBlock* = ref object of Node
    body*: Block
  Reflect* = ref object of Node
    `type`*: `Type`
  Embed* = ref object of Node
    path*: string
    `type`*: `Type`
  Derive* = ref object of Node
    traits*: seq[Name]

  Constant* = ref object of Node
    public*: bool
    plural*: bool
    evaluated*: bool
    name*: Name
    `type`*: `Type`
    value*: Expression
  Mutable* = ref object of Node
    public*: bool
    plural*: bool
    name*: Name
    `type`*: `Type`
    value*: Expression
  Destructure* = ref object of Node
    recordType*: `Type`
    fields*: seq[Name]
    bindings*: seq[Name]
    value*: Expression
  Function* = ref object of Node
    public*: bool
    name*: Name
    dispatch*: string
    typeParams*: seq[TypeParam]
    params*: seq[Parameter]
    returnType*: `Type`
    abi*: string
    constraint*: Constraint
    constraints*: seq[Constraint]
    attributes*: seq[string]
    guard*: Expression
    body*: Block
  Alias* = ref object of Node
    public*: bool
    name*: Name
    typeParams*: seq[TypeParam]
    body*: Node
    derives*: Derive
    constraints*: seq[Constraint]
    attributes*: seq[string]
  Use* = ref object of Node
    alias*: Name
    public*: bool
    name*: Name
    path*: string
  NativeCode* = object
    substrate*: string
    code*: string
  ExternFunction* = ref object of Node
    native*: NativeCode
    typeParams*: seq[TypeParam]
    constraints*: seq[Constraint]
    symbol*: string
    public*: bool
    abi*: string
    name*: Name
    params*: seq[Parameter]
    returnType*: `Type`
  CImport* = ref object of Node
    header*: string
  Native* = ref object of Node
    code*: string
    substrate*: string
  Give* = ref object of Node
    value*: Expression
  `When`* = ref object of Node
    cond*: Expression
    `then`*: Block
    `else`*: Node
  `While`* = ref object of Node
    cond*: Expression
    body*: Block
  `For`* = ref object of Node
    `bind`*: Name
    iter*: Expression
    body*: Block
  Match* = ref object of Node
    scrutinee*: Expression
    cases*: seq[`Case`]
  `Break`* = ref object of Node
  `Continue`* = ref object of Node
  `Defer`* = ref object of Node
    body*: Node
    error*: bool
  Unsafe* = ref object of Node
    body*: Block
  Action* = ref object of Node
    name*: Name
    args*: seq[Expression]
    value*: Expression
  `Case`* = ref object of Node
    pattern*: Pattern
    guard*: Expression
    body*: Block
  UnreachableStatement* = ref object of Node
  TestBlock* = ref object of Node
    name*: Text
    body*: Block

  Record* = ref object of Node
    fields*: seq[Member]
    layout*: string
  Member* = ref object of Node
    name*: Name
    `type`*: `Type`
    attributes*: seq[string]
  Choice* = ref object of Node
    variants*: seq[Variant]
  Variant* = ref object of Node
    name*: Name
    value*: Integer
    payload*: `Type`
  Union* = ref object of Node
    fields*: seq[Member]
    layout*: string
  Opaque* = ref object of Node

  Primitive* = ref object of Node
    name*: string
    width*: string
  Sequence* = ref object of Node
    elem*: `Type`
    constant*: bool
  Optional* = ref object of Node
    elem*: `Type`
  Error* = ref object of Node
    elem*: `Type`
  Pointer* = ref object of Node
    elem*: `Type`
  Named* = ref object of Node
    name*: Name
  Vector* = ref object of Node
    length*: string
    elem*: `Type`
  FunctionType* = ref object of Node
    params*: seq[`Type`]
    ret*: `Type`
    abi*: string

  Parameter* = ref object of Node
    name*: Name
    `type`*: `Type`
    default*: Expression
    variadic*: bool
  Constraint* = ref object of Node
    subject*: Name
    trait*: Name
  Block* = ref object of Node
    stmts*: seq[Statement]
  Wildcard* = ref object of Node
  VariantPattern* = ref object of Node
    name*: Name
    binding*: Name
  Broken* = ref object of Node
