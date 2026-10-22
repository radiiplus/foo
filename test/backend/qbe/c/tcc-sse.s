.text
.globl qbe_sse_probe
qbe_sse_probe:
    movsd %xmm0, %xmm2
    cvtsd2ss %xmm2, %xmm2
    cvtss2sd %xmm2, %xmm2
    addsd %xmm1, %xmm2
    cvttsd2si %xmm2, %rax
    cvtsi2sd %rax, %xmm0
    ret
