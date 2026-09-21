# Errors

Version: 1.

`fallible T` has two states: a successful T, or one Error with a trace.
Error is a single open nominal type. There are no error sets and no per-function
lists of possible errors.

An error identity is a stable UTF-8 name. Packages define named constants with
a package-qualified identity:

```iv
public constant Missing of type Error is Error("example/files:Missing").
```

The Error constructor requires a constant identity belonging to the declaring
package. The standard Error identities include Allocation, Size, Bounds,
Closed, Invalid, Unsupported and Cancelled. Equality compares identity, not
human-readable descriptions or trace addresses. New identities do not change
a fallible function's signature.

`fail(error)` constructs a failure; it is a polymorphic operation whose success
type is bottom. Ordinary Error values never implicitly become failures, so
`fallible Error` can carry a successful Error without ambiguity.

```iv
function unavailable() of type fallible text {
  give fail(Error.Unsupported).
}

function read() of type fallible text {
  give try unavailable().
}

start() {
  constant value is read() catch "default".
  give nothing.
}
```

Try unwraps success and propagates failure to the enclosing fallible function.
Applying try in an explicitly infallible function is an error.
Catch evaluates its fallback once, only on failure. Both success and fallback
must have a common result type; a fallible fallback may preserve failure.
Catch is an expression, not an exception-handler block.

Every discarded fallible result must be handled. `start()` permits propagation:
a propagated failure reports the error and exits unsuccessfully.
A successful `give nothing.` exits successfully. Neither path guesses an error
category from a numeric return code.

## Trace and cleanup

A trace records the origin and propagation sites of a failure in source order.
Entries contain package/file identity and source span, not substrate filenames.
Rethrowing preserves the original identity and trace, adding the propagation
site. Local recovery consumes that failure; a new failure has its own origin.
Trace storage must survive the scopes exited during propagation.

```iv
function sample() of type fallible nothing {
  constant handle is try open().
  after { close(handle) catch nothing. }
  after error { report("operation failed"). }
  try consume(handle).
  give nothing.
}
```

After registers cleanup on every ordinary scope exit. After error registers
cleanup only when a failure propagates out of that scope. Both share a single
reverse-registration ordering. A caught error followed by normal return does
not trigger error-only cleanup.

Deferred blocks cannot propagate another error or alter control flow. Handle
their own failures locally. All cleanup completes before scope storage is
reclaimed. Panic is a separate, nonrecoverable edge: catch does not catch panic,
and cleanup after panic is not guaranteed.

Failure identity and human diagnostics are separate contracts. Foreign calls
translate their own error conventions explicitly; foreign exception unwinding
must not cross a FOO boundary. See [ABI](abi.md) and
[diagnostics](diagnostics.md).
