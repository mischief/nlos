/* one stub per vector: vectors 8, 10-14, 17, 21, 29, 30 push a
 * hardware error code before the CPU gets to iretq; everything else
 * doesn't, so we push a dummy 0 to keep the frame shape uniform. all
 * 256 stubs exist (not just the 32 architectural exceptions) so an
 * unexpected vector still lands on trap_common and gets reported
 * instead of silently double-faulting into nothing.
 */

	.altmacro

	.macro stub_noerr num
	.pushsection .text
	.globl	isr_stub_\num
isr_stub_\num:
	pushq	$0
	pushq	$\num
	jmp	trap_common
	.popsection
	.pushsection .rodata
	.quad	isr_stub_\num
	.popsection
	.endm

	.macro stub_err num
	.pushsection .text
	.globl	isr_stub_\num
isr_stub_\num:
	pushq	$\num
	jmp	trap_common
	.popsection
	.pushsection .rodata
	.quad	isr_stub_\num
	.popsection
	.endm

	.section .rodata
	.globl	isr_stub_table
isr_stub_table:

	.set i, 0
	.rept 256
	.if i == 8 || (i >= 10 && i <= 14) || i == 17 || i == 21 || i == 29 || i == 30
	stub_err %i
	.else
	stub_noerr %i
	.endif
	.set i, i + 1
	.endr

/* common trap entry: save the general registers the C handler wants to
 * print, call idt_dispatch(vector, errcode, frame), and (for now) never
 * return -- every fault is fatal in this slice, see idt.c.
 */
	.text
	.globl	trap_common
trap_common:
	pushq	%rax
	pushq	%rbx
	pushq	%rcx
	pushq	%rdx
	pushq	%rsi
	pushq	%rdi
	pushq	%rbp
	pushq	%r8
	pushq	%r9
	pushq	%r10
	pushq	%r11
	pushq	%r12
	pushq	%r13
	pushq	%r14
	pushq	%r15

	movq	%rsp, %rdi	/* struct trapframe * */
	call	idt_dispatch
	/* idt_dispatch does not return in this slice (see idt.c) */
1:	hlt
	jmp	1b

/* the LAPIC timer gets its own entry rather than a slot in the generic
 * (fatal) table above: it is the one interrupt in this slice that must
 * actually resume the interrupted proc. no vector/errcode pushed --
 * lapic_timer_isr() (idt.c) takes no argument -- and it must return
 * before iretq, unlike trap_common above.
 */
	.globl	isr_timer
isr_timer:
	pushq	%rax
	pushq	%rcx
	pushq	%rdx
	pushq	%rsi
	pushq	%rdi
	pushq	%r8
	pushq	%r9
	pushq	%r10
	pushq	%r11

	call	lapic_timer_isr

	popq	%r11
	popq	%r10
	popq	%r9
	popq	%r8
	popq	%rdi
	popq	%rsi
	popq	%rdx
	popq	%rcx
	popq	%rax
	iretq

	.section .note.GNU-stack, "", @progbits
