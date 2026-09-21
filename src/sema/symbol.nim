import ../ast/node
import ./form

type Symbol* = object
  name*: string
  form*: Form
  visible*: bool
  node*: Node
  module*: string
  qualified*: string
