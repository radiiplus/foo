extern double __attribute__((vectorcall)) tcc_vectorcall_mix(
    double a, int b, double c, int d, double e, double f);
extern int tcc_calls_peer_vectorcall(void);

double __attribute__((vectorcall)) peer_vectorcall_mix(
    double a, int b, double c, int d, double e, double f)
{
    return a + b * 2 + c * 4 + d * 8 + e * 16 + f * 32;
}

int main(void)
{
    return tcc_vectorcall_mix(1, 2, 3, 4, 5, 6) == 321 &&
           tcc_calls_peer_vectorcall() ? 0 : 1;
}
