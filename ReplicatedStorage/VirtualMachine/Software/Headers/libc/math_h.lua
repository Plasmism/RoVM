local math_h = [[
#ifndef MATH_H
#define MATH_H
#include "rovm.h"
#define FIXPOINT_SHIFT 16
#define FIXPOINT_ONE (1 << 16)

#define fix_from_int(x) ((x) << 16)
#define fix_to_int(x) ((x) >> 16)

#define __math_syscall(op, arg1, arg2) syscall(64, (op), (arg1), (arg2))

#define fix_mul(a, b) __math_syscall(10, (a), (b))
#define fix_div(a, b) __math_syscall(11, (a), (b))
#define fix_sin(angle) __math_syscall(0, (angle), 0)
#define fix_cos(angle) __math_syscall(1, (angle), 0)
#define fix_tan(angle) __math_syscall(2, (angle), 0)
#define fix_sqrt(val) __math_syscall(3, (val), 0)
#define fix_atan2(y, x) __math_syscall(4, (y), (x))

int isqrt(int n) {
    if (n < 0) return 0;
    if (n < 2) return n;
    int x = n; int y = (x + 1) / 2;
    while (y < x) { x = y; y = (x + n / x) / 2; }
    return x;
}
#endif
]]

return math_h