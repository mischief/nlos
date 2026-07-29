/* lp64d setjmp/longjmp.
 * callee-saved state: ra (x1), sp (x2), s0-s11 (x8, x9, x18-x27) and
 * fs0-fs11 (f8, f9, f18-f27). jmp_buf is 26 words -- see
 * include/setjmp.h. the fs registers are saved because we build with
 * the hard-float abi, where they are the callee's to preserve.
 */

	.text
	.globl	setjmp
	.type	setjmp, %function
setjmp:
	sd	ra, 0(a0)
	sd	sp, 8(a0)
	sd	s0, 16(a0)
	sd	s1, 24(a0)
	sd	s2, 32(a0)
	sd	s3, 40(a0)
	sd	s4, 48(a0)
	sd	s5, 56(a0)
	sd	s6, 64(a0)
	sd	s7, 72(a0)
	sd	s8, 80(a0)
	sd	s9, 88(a0)
	sd	s10, 96(a0)
	sd	s11, 104(a0)
	fsd	fs0, 112(a0)
	fsd	fs1, 120(a0)
	fsd	fs2, 128(a0)
	fsd	fs3, 136(a0)
	fsd	fs4, 144(a0)
	fsd	fs5, 152(a0)
	fsd	fs6, 160(a0)
	fsd	fs7, 168(a0)
	fsd	fs8, 176(a0)
	fsd	fs9, 184(a0)
	fsd	fs10, 192(a0)
	fsd	fs11, 200(a0)
	li	a0, 0
	ret
	.size	setjmp, . - setjmp

	.globl	longjmp
	.type	longjmp, %function
longjmp:
	ld	ra, 0(a0)
	ld	sp, 8(a0)
	ld	s0, 16(a0)
	ld	s1, 24(a0)
	ld	s2, 32(a0)
	ld	s3, 40(a0)
	ld	s4, 48(a0)
	ld	s5, 56(a0)
	ld	s6, 64(a0)
	ld	s7, 72(a0)
	ld	s8, 80(a0)
	ld	s9, 88(a0)
	ld	s10, 96(a0)
	ld	s11, 104(a0)
	fld	fs0, 112(a0)
	fld	fs1, 120(a0)
	fld	fs2, 128(a0)
	fld	fs3, 136(a0)
	fld	fs4, 144(a0)
	fld	fs5, 152(a0)
	fld	fs6, 160(a0)
	fld	fs7, 168(a0)
	fld	fs8, 176(a0)
	fld	fs9, 184(a0)
	fld	fs10, 192(a0)
	fld	fs11, 200(a0)
	mv	a0, a1
	bnez	a1, 1f
	li	a0, 1			/* longjmp(env, 0) returns 1 */
1:
	ret
	.size	longjmp, . - longjmp

	.section .note.GNU-stack, "", %progbits
