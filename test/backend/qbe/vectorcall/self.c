extern double __vectorcall tcc_vectorcall_mix(
    double a, int b, double c, int d, double e, double f);
extern int tcc_calls_peer_vectorcall(void);
typedef double (__vectorcall *vectorcall_mix_pointer)(
    double, int, double, int, double, double);

static int call_through_pointer(vectorcall_mix_pointer callback)
{
    return callback(1, 2, 3, 4, 5, 6) == 321;
}

double __vectorcall peer_vectorcall_mix(
    double a, int b, double c, int d, double e, double f)
{
    return a + b * 2 + c * 4 + d * 8 + e * 16 + f * 32;
}

int main(void)
{
    return tcc_vectorcall_mix(1, 2, 3, 4, 5, 6) == 321 &&
           call_through_pointer(tcc_vectorcall_mix) &&
           tcc_calls_peer_vectorcall() ? 0 : 1;
}
