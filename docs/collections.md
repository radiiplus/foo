# Collections

FOO v1 creates collections through standard-library modules. It does not use
collection literal syntax such as `[1, 2, 3]` or `{ "key": value }`.

## Sequences

A sequence stores values of one type. Updates return a new logical value. Older
values keep their original lengths and contents even when append reuses unused
space in a shared backing buffer.

```foo
use sequence as sequences.

constant empty is sequences.create[integer]().
constant one is sequences.append[integer](empty, 4) try.
constant values is sequences.append[integer](one, 9) try.

after {
  sequences.release[integer](one) fallback nothing.
  sequences.release[integer](values) fallback nothing.
}
```

`append` does not change anything visible through `empty` or `one`. Consecutive
results can share storage, so release each retained append result once after all
of its aliases stop being used. A plain assignment is only another name for the
same result and must not be released separately. The empty value owns no heap
storage (memory kept beyond the current function call) and does not need release.

Appending repeatedly to the newest result is amortized O(1) (many appends
average to constant work per append). Appending from an
older result creates an independent branch by copying that older prefix. This
keeps persistence without copying the full sequence on every newest append.

## Exact-size construction

Use `sized` when the final element count is already known. It allocates the
sequence payload once, initializes every element, and avoids the repeated
allocation and copying required by persistent `append`.

```foo
constant values is sequences.sized[integer](10_000) try.
dynamic index is 0.
while index less than 10_000 {
  set values at index to index.
  increase index by 1.
}
```

The size calculation is checked for overflow, and allocation failure remains a
normal failable result. `sized` is intended for construction before aliases are
published. Use `append` when the final size is not known or earlier sequence
values must remain valid.

## Length and indexing

```foo
constant count is sequences.length[integer](values).
constant first is values at 0.
```

Indexes start at zero and are checked. Access outside the valid range is an
error rather than an unchecked memory read.

## Iteration

```foo
for each value in values {
  inspect(value).
}
```

The loop visits sequence values in order.

## Transformations

```foo
function double(value integer) giving integer {
  give value multiply 2.
}

function positive(value integer) giving boolean {
  give value greater than 0.
}

constant doubled is sequences.map[integer, integer](values, double) try.
constant kept is sequences.filter[integer](doubled, positive) try.
constant unique is sequences.deduplicate[integer](kept) try.

after {
  sequences.release[integer](doubled) fallback nothing.
  sequences.release[integer](kept) fallback nothing.
  sequences.release[integer](unique) fallback nothing.
}
```

`map`, `filter`, `sort`, `copy`, and `deduplicate` return new storage. Releasing
one result does not release the others.

## Persistent maps

The `map` module stores typed keys and values. Like sequences, changes return a
new map.

```foo
use map as maps.

constant empty is maps.create[text, integer]().
constant first is maps.put[text, integer](empty, "answer", 41) try.
constant updated is maps.put[text, integer](first, "answer", 42) try.
constant answer is maps.get[text, integer](updated, "answer") try.

after {
  maps.release[text, integer](first) fallback nothing.
  maps.release[text, integer](updated) fallback nothing.
}
```

`get` is failable because a key may be absent. `contains` checks before a read
when absence is part of ordinary control flow.

## Mutable hash maps (key-based collections using fingerprints for lookup)

Use `table` for mutable text-keyed lookup when in-place updates are more
appropriate than persistent values.

```foo
use table as lookup.

constant table is lookup.create[integer]() try.
after { lookup.close[integer](table) fallback nothing. }

lookup.put[integer](table, "answer", 42) try.
constant answer is lookup.get[integer](table, "answer") try.
```

Hash-map iteration order is not stable. Do not use it when output order is part
of the program's contract.

## Other collection modules

| Module | Main operations |
| --- | --- |
| `set` | `create`, `insert`, `contains`, `remove`, `length`, `release` |
| `queue` | `create`, `append`, `first`, `remove`, `length`, `release` |
| `stack` | `create`, `push`, `top`, `remove`, `length`, `release` |
| `list` | Linked-list creation, traversal, and release operations. |

Read [The standard library](library.md) for module-level details.

## Common mistakes

| Problem | Fix |
| --- | --- |
| Expecting `append` to mutate | Bind the returned sequence. |
| Building a known-size sequence with repeated `append` | Allocate once with `sized`, then fill its elements. |
| Forgetting `try` | Propagate or recover from the allocation failure. |
| Releasing an alias too early | Release only after every use of that owned value. |
| Expecting hash-map order | Use an ordered sequence or persistent map workflow. |

Next: [Error handling](errors.md).
