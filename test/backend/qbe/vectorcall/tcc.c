double __vectorcall tcc_vectorcall_mix(
    double a, int b, double c, int d, double e, double f)
{
    return a + b * 2 + c * 4 + d * 8 + e * 16 + f * 32;
}

extern double __vectorcall peer_vectorcall_mix(
    double a, int b, double c, int d, double e, double f);

int tcc_calls_peer_vectorcall(void)
{
    return peer_vectorcall_mix(1, 2, 3, 4, 5, 6) == 321;
}
