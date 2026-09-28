# Operators

FOO uses words for arithmetic, comparison, and Boolean logic. The words make
an expression readable, but the compiler still applies precise precedence
rules.

## Arithmetic

| Operation | FOO expression | Result |
| --- | --- | --- |
| Addition | `8 plus 2` | `10` |
| Subtraction | `8 subtract 2` | `6` |
| Multiplication | `8 multiply 2` | `16` |
| Division | `8 divide 2` | `4` |
| Remainder | `8 remainder 3` | `2` |

`multiply` and `divide` bind more tightly than `plus` and `subtract`:

```foo
constant first is 2 plus 3 multiply 4.    -- 14
constant second is (2 plus 3) multiply 4. -- 20
```

Use parentheses whenever they make the intended grouping clearer.

## Equality

```foo
constant left is 4.
constant right is 4.
constant same is left is right.
constant different is left is not right.
```

Equality requires compatible values. Comparing unrelated types is a compile
error rather than an automatic conversion.

## Ordering

Prefer a direct positive comparison:

```foo
constant age is 21.

when age greater than or equal to 18 {
  display "Adult".
}
```

The complete comparison vocabulary is:

| Meaning | Expression |
| --- | --- |
| Greater | `left greater than right` |
| Less | `left less than right` |
| At least | `left greater than or equal to right` |
| At most | `left less than or equal to right` |

Use the direct forms in the table consistently.

## Boolean logic

```foo
constant signed is true.
constant allowed is true.
constant visible is false.
constant approved is signed and allowed.
constant preview is signed or visible.
constant blocked is not approved.
```

Precedence from strongest to weakest is:

1. Parenthesized expressions.
2. `multiply`, `divide`, and `remainder`.
3. `plus` and `subtract`.
4. Comparisons such as `is` and `greater than`.
5. `not`.
6. `and`.
7. `or`.
8. `fallback`.

## Updating a dynamic value

Arithmetic does not mutate a binding by itself. Use `set`:

```foo
dynamic total is 10.
set total to total plus 5.
set total to total multiply 2.
```

For addition and subtraction, the shorter mutation statements describe intent
without repeating the target:

```foo
dynamic total is 10.
increase total by 5.
decrease total by 2.
```

Both retain FOO's overflow checks and require a `dynamic` target.

## Try it

1. Predict `10 subtract 2 multiply 3` before checking it.
2. Add parentheses to produce a different result.
3. Write a condition that is true only when `score` is between 10 and 20.
4. Rewrite a negative condition as a positive comparison.

Next: [Conditions and loops](flow.md).
