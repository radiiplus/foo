import std/tables
import ./type

type State = object
  mutable: bool
  initialized: bool
  identity: int
type Environment* = ref object
  parent: Environment
  types: Table[string, Type]
  states: Table[string, State]

var nextIdentity = 0
proc newEnvironment*(parent: Environment = nil): Environment = Environment(parent: parent, types: initTable[string, Type](), states: initTable[string, State]())
proc define*(environment: Environment; name: string; value: Type; mutable = false; initialized = true) =
  inc nextIdentity
  environment.types[name] = value
  environment.states[name] = State(mutable: mutable, initialized: initialized, identity: nextIdentity)
proc mutable*(environment: Environment; name: string): bool =
  if name in environment.states: environment.states[name].mutable elif environment.parent != nil: environment.parent.mutable(name) else: false
proc initialized*(environment: Environment; name: string): bool =
  if name in environment.states: environment.states[name].initialized elif environment.parent != nil: environment.parent.initialized(name) else: true
proc initialize*(environment: Environment; name: string) =
  if name in environment.states: environment.states[name].initialized = true
  elif environment.parent != nil: environment.parent.initialize(name)
proc lookup*(environment: Environment; name: string): Type =
  if name in environment.types: environment.types[name] elif environment.parent != nil: environment.parent.lookup(name) else: nil
proc names*(environment: Environment): seq[string] =
  if environment.parent != nil: result = environment.parent.names
  for name in environment.types.keys:
    if name notin result: result.add(name)
proc child*(environment: Environment): Environment = newEnvironment(environment)
proc join*(environment: Environment; branches: seq[Environment]) =
  for name in environment.names:
    if name notin environment.states: continue
    let state = environment.states[name]
    var allReady = true
    for branch in branches:
      if name notin branch.states or branch.states[name].identity != state.identity or not branch.initialized(name): allReady = false
    if allReady: environment.initialize(name)
