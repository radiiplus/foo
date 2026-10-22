#if !defined(FOO_SERVICE_SELECTIVE) || defined(FOO_SERVICE_ATOMIC)
typedef struct { _Atomic uint64_t value; } Atom;
static bool ordering(FooText text, memory_order *order) {
  if (supports(text, "relaxed")) *order = memory_order_relaxed;
  else if (supports(text, "acquire")) *order = memory_order_acquire;
  else if (supports(text, "release")) *order = memory_order_release;
  else if (supports(text, "both")) *order = memory_order_acq_rel;
  else if (supports(text, "sequential")) *order = memory_order_seq_cst;
  else return false;
  return true;
}
FooResult foo_atomic_create(uint64_t value) {
  Atom *atom = malloc(sizeof(*atom));
  if (!atom) return failure(MEMORY);
  atomic_init(&atom->value, value);
  return (FooResult){.pointer = atom};
}
FooResult foo_atomic_release(void *value) { free(value); return (FooResult){0}; }
FooResult foo_atomic_load(void *value, FooText text) {
  memory_order order;
  if (!ordering(text, &order)) return failure(INVALID_ORDER);
  if (order == memory_order_release || order == memory_order_acq_rel)
    return failure(INVALID_LOAD_ORDER);
  return (FooResult){.number = atomic_load_explicit(&((Atom *)value)->value, order)};
}
FooResult foo_atomic_store(void *value, uint64_t number, FooText text) {
  memory_order order;
  if (!ordering(text, &order)) return failure(INVALID_ORDER);
  if (order == memory_order_acquire || order == memory_order_acq_rel)
    return failure(INVALID_STORE_ORDER);
  atomic_store_explicit(&((Atom *)value)->value, number, order);
  return (FooResult){0};
}
FooResult foo_atomic_add(void *value, uint64_t number, FooText text) {
  memory_order order;
  if (!ordering(text, &order)) return failure(INVALID_ORDER);
  return (FooResult){.number = atomic_fetch_add_explicit(&((Atom *)value)->value, number, order)};
}
FooResult foo_atomic_deduct(void *value, uint64_t number, FooText text) {
  memory_order order;
  if (!ordering(text, &order)) return failure(INVALID_ORDER);
  return (FooResult){.number = atomic_fetch_sub_explicit(&((Atom *)value)->value, number, order)};
}
FooResult foo_atomic_swap(void *value, uint64_t number, FooText text) {
  memory_order order;
  if (!ordering(text, &order)) return failure(INVALID_ORDER);
  return (FooResult){.number = atomic_exchange_explicit(&((Atom *)value)->value, number, order)};
}
FooResult foo_atomic_replace(void *value, uint64_t expected, uint64_t number, FooText text) {
  memory_order order;
  if (!ordering(text, &order)) return failure(INVALID_ORDER);
  return (FooResult){.number = atomic_compare_exchange_strong_explicit(
    &((Atom *)value)->value, &expected, number, order, memory_order_relaxed)};
}
FooResult foo_atomic_compare(void *value, uint64_t expected, uint64_t number,
                             FooText success_text, FooText failure_text) {
  memory_order success, failure_order;
  if (!ordering(success_text, &success) || !ordering(failure_text, &failure_order) ||
      failure_order == memory_order_release || failure_order == memory_order_acq_rel ||
      (failure_order == memory_order_acquire && success != memory_order_acquire &&
       success != memory_order_acq_rel && success != memory_order_seq_cst) ||
      (failure_order == memory_order_seq_cst && success != memory_order_seq_cst))
    return failure(INVALID_ORDER);
  return (FooResult){.number = atomic_compare_exchange_strong_explicit(
    &((Atom *)value)->value, &expected, number, success, failure_order)};
}
#endif
