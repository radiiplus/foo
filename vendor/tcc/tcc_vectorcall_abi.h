#ifndef FOO_TCC_VECTORCALL_ABI_H
#define FOO_TCC_VECTORCALL_ABI_H

/* Microsoft x64 vectorcall assigns scalar registers by parameter position. */
static int vectorcall_xmm_slot(int position, int type)
{
    int basic = type & VT_BTYPE;
    return position < 6 && (basic == VT_FLOAT || basic == VT_DOUBLE)
        ? position : -1;
}

#endif
