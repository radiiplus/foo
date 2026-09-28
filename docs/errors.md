# Error Handling

FOO makes possible failure visible in a function's type. A function giving
`failable text` produces text on success or an error on failure.

## A failable operation

```foo
use file as files.

function settings() giving failable text {
  give files.read("settings.json") try.
}
```

`try` follows the operation it modifies. If the read succeeds, execution
continues with its text. If it fails, the current failable function returns the
error to its caller.

## Postfix `try`

This complete function shows the canonical forms (the standard forms new code
should use):

```foo
use file as files.

function copy() giving failable text {
  constant content is files.read("notes.txt") try.
  files.write("copy.txt", content) try.
  give content.
}
```

`try` is a postfix operator on one failable expression. It binds to the value
immediately before it, so use parentheses when the propagated value
participates in a larger expression. Repeating `try` is valid only when each
application unwraps another failable layer.

## `fallback`

Use `fallback` when the current scope can supply a valid replacement.

```foo
use file as files.

constant settings is files.read("settings.json") fallback "{}".
display settings.
```

The replacement must have the same success type. A fallback for `failable
text` must produce text.

`fallback` handles the error locally. It does not propagate it.

Every failable value must be propagated with `try`, recovered with `fallback`,
returned from a compatible failable function, or otherwise consumed by an API
that explicitly accepts it. `failable nothing` can still report failure;
plain `nothing` cannot.

## Choosing between them

| Situation | Use |
| --- | --- |
| The caller should decide | Postfix `try` |
| A default value is genuinely valid | `fallback value` |
| The operation is cleanup and failure is intentionally ignored | `fallback nothing` |
| Failure should terminate the process | An explicit panic or top-level policy |

Do not use a fallback merely to silence the compiler. A default that changes
the meaning of the operation can hide data loss or configuration mistakes.

## Cleanup with `after`

Register cleanup immediately after acquiring a resource.

```foo
use file as files.
use io as streams.

function chunk() giving failable text {
  constant stream is files.open("data.txt", "read") try.
  after { streams.close(stream) fallback nothing. }
  give streams.read(stream, 4096) try.
}
```

The `after` block runs on ordinary completion, early `give`, propagated
failure, `stop`, and `skip`. Forced process termination cannot guarantee it.
Several cleanup blocks in one scope run in reverse registration order. A block
belongs to its nearest enclosing scope, so one registered inside a loop runs
when that iteration's scope exits.

## Cleanup only after failure

`after error` is useful while constructing an owned result. It runs if the
scope exits through failure but not after a successful return.

```foo
use memory.

constant allocator is memory.system().
constant buffer is memory.allocate(allocator, 4096) try.
after error { memory.release(allocator, buffer) fallback nothing. }
```

Use this form when ownership transfers to the caller on success.
`after error` follows the same scope and reverse-order rules, but runs only
while a failure is leaving that scope; `stop`, `skip`, and a successful `give`
do not trigger it.

## Error context

Low-level operations should retain useful context when errors cross module
boundaries. Do not replace every failure with the same generic fallback.
Terminal diagnostics group repeated compiler errors, while JSON and LSP
(Language Server Protocol, used by code editors) output
keep one precise record per source location.

## Common mistakes

| Problem | Fix |
| --- | --- |
| Writing `is try` | Bind the expression, then put `try` after the call. |
| Ignoring a failable call | Add postfix `try` or a meaningful `fallback`. |
| Using a fallback of another type | Return the success type of the operation. |
| Registering cleanup too late | Put `after` immediately after acquisition. |

Next: [Modules and packages](modules.md).
