#ifndef _SETJMP_H
#define _SETJMP_H

/* callee-saved state, per abi -- see src/<arch>/setjmp.S.
 * x86_64: rbx rbp r12 r13 r14 r15 rsp rip
 * aarch64: x19-x28 x29 x30 sp d8-d15, 21 words rounded up to a pair
 */
#if defined(__aarch64__)
typedef unsigned long jmp_buf[22];
#else
typedef unsigned long jmp_buf[8];
#endif

int	setjmp(jmp_buf env);
_Noreturn void longjmp(jmp_buf env, int val);

#endif
