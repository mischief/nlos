/* aapcs64 setjmp/longjmp.
 * callee-saved state: x19-x28, x29 (fp), x30 (lr), sp, and the low
 * halves of v8-v15. jmp_buf is 22 words -- see include/setjmp.h.
 */

	.text
	.globl	setjmp
	.type	setjmp, %function
setjmp:
	stp	x19, x20, [x0, #0]
	stp	x21, x22, [x0, #16]
	stp	x23, x24, [x0, #32]
	stp	x25, x26, [x0, #48]
	stp	x27, x28, [x0, #64]
	stp	x29, x30, [x0, #80]
	mov	x1, sp
	str	x1, [x0, #96]
	stp	d8, d9, [x0, #104]
	stp	d10, d11, [x0, #120]
	stp	d12, d13, [x0, #136]
	stp	d14, d15, [x0, #152]
	mov	w0, #0
	ret
	.size	setjmp, . - setjmp

	.globl	longjmp
	.type	longjmp, %function
longjmp:
	ldp	x19, x20, [x0, #0]
	ldp	x21, x22, [x0, #16]
	ldp	x23, x24, [x0, #32]
	ldp	x25, x26, [x0, #48]
	ldp	x27, x28, [x0, #64]
	ldp	x29, x30, [x0, #80]
	ldr	x2, [x0, #96]
	mov	sp, x2
	ldp	d8, d9, [x0, #104]
	ldp	d10, d11, [x0, #120]
	ldp	d12, d13, [x0, #136]
	ldp	d14, d15, [x0, #152]
	mov	w0, w1
	cmp	w1, #0
	csinc	w0, w0, wzr, ne		/* longjmp(env, 0) returns 1 */
	ret
	.size	longjmp, . - longjmp

	.section .note.GNU-stack, "", %progbits
