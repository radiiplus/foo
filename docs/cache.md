# Build Cache

QBE artifact metadata uses `.qbe.json` sidecars. Build identity includes the
target, mode, lowering policy, compiler tools and hashes of runtime and native
inputs. A changed source, tool or native input invalidates the relevant result.

`foo build --backend qbe --explain` reports build decisions. Keep cache and
artifact directories under `.artifacts` when running independent gates. Current
target qualification is listed in [QBE Backend Support](qbe.md).
