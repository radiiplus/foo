/* Required compiler support for the qualified Clang Windows x64 ABI.
   No division/remainder operations: these definitions cannot recurse into
   themselves through a compiler-generated 128-bit division libcall. */
typedef unsigned __int128 foo_wide_unsigned;
typedef __int128 foo_wide_signed;

static foo_wide_unsigned foo_wide_divmod(foo_wide_unsigned dividend,
                                        foo_wide_unsigned divisor,
                                        foo_wide_unsigned *remainder) {
  foo_wide_unsigned quotient = 0, rest = 0;
  for (unsigned bit = 0; bit < 128; ++bit) {
    unsigned carry = (unsigned)(rest >> 127);
    rest = (rest << 1) | (dividend >> 127);
    dividend <<= 1;
    quotient <<= 1;
    if (carry || rest >= divisor) { rest -= divisor; quotient |= 1; }
  }
  *remainder = rest;
  return quotient;
}

foo_wide_unsigned __udivti3(foo_wide_unsigned a, foo_wide_unsigned b) {
  foo_wide_unsigned r;
  return foo_wide_divmod(a,b,&r);
}
foo_wide_unsigned __umodti3(foo_wide_unsigned a, foo_wide_unsigned b) {
  foo_wide_unsigned r;
  (void)foo_wide_divmod(a,b,&r);
  return r;
}
static foo_wide_unsigned foo_wide_magnitude(foo_wide_signed value) {
  /* Unsigned subtraction is defined even for the minimum signed value. */
  return value < 0 ? (foo_wide_unsigned)0 - (foo_wide_unsigned)value
                   : (foo_wide_unsigned)value;
}
foo_wide_signed __divti3(foo_wide_signed a, foo_wide_signed b) {
  foo_wide_unsigned r;
  foo_wide_unsigned q = foo_wide_divmod(foo_wide_magnitude(a),foo_wide_magnitude(b),&r);
  return (foo_wide_signed)((a < 0) != (b < 0) ? (foo_wide_unsigned)0 - q : q);
}
foo_wide_signed __modti3(foo_wide_signed a, foo_wide_signed b) {
  foo_wide_unsigned r;
  (void)foo_wide_divmod(foo_wide_magnitude(a),foo_wide_magnitude(b),&r);
  return (foo_wide_signed)(a < 0 ? (foo_wide_unsigned)0 - r : r);
}
