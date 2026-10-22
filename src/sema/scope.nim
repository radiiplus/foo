import std/tables
import ./symbol

type Scope* = ref object
  parent: Scope
  symbols: Table[string, Symbol]

proc scope*(parent: Scope = nil): Scope = Scope(parent: parent, symbols: initTable[string, Symbol]())
proc insert*(scope: Scope; name: string; symbol: Symbol): bool =
  if name in scope.symbols: return false
  scope.symbols[name] = symbol
  true
proc lookup*(scope: Scope; name: string): tuple[found: bool, symbol: Symbol] =
  if name in scope.symbols: return (true, scope.symbols[name])
  if scope.parent != nil: return scope.parent.lookup(name)
  (false, Symbol())
proc local*(scope: Scope; name: string): tuple[found: bool, symbol: Symbol] =
  if name in scope.symbols: (true, scope.symbols[name]) else: (false, Symbol())
