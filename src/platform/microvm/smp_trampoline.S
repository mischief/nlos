/* where an application processor starts, which the architecture says
 * must be a 4K page below 1MB, entered in real mode.
 *
 * That is the whole reason this is not in boot.S. The kernel loads at
 * 0x100000 and main.c's claim_memory deliberately never gives the
 * allocator anything below it, so there is no low page to be had by
 * asking: smp.c copies the bytes between smp_tramp_start and
 * smp_tramp_end down to SMP_TRAMP_BASE itself.
 *
 * Because it is copied, the 16-bit half cannot be linked where it runs.
 * Every address it touches is written as an offset from
 * smp_tramp_start, which is exactly what the segment registers make an
 * effective address out of once ds is pointed at the page. The 32-bit
 * half has no such problem -- by then the cpu can reach the whole
 * address space and the kernel's own symbols are usable -- so this
 * leaves real mode as fast as it can and does the rest in ordinary
 * text.
 *
 * The page tables, both gdts and the mode-switch sequence are boot.S's,
 * reused rather than reproduced. An AP wants precisely the same machine
 * state the BSP built for itself, and one CR3 for the whole machine is
 * deliberate: there are no per-process address spaces here to want
 * anything else.
 *
 * plan9front's sys/src/9/pc64/apbootstrap.s is the same code with the
 * same shape, and is the version that has actually been run on a lot of
 * hardware.
 */

#include "smp.h"

#define TRAMP(x) ((x) - smp_tramp_start)

	.section .rodata
	.align 16
	.code16
	.globl	smp_tramp_start
smp_tramp_start:
	/* the two handoff slots the BSP fills in. They are at the front
	 * at fixed offsets so that C and assembler agree about where
	 * they are without either computing anything; smp.h names them.
	 */
	jmp	start16
	.align 8
	.quad	0			/* SMP_OFF_STACK */
	.quad	0			/* SMP_OFF_INDEX */

gdt32_ptr16:
	.word	SMP_GDT32_LIMIT
	.long	gdt32

start16:
	cli
	cld

	/* a SIPI leaves cs = vector << 8 and everything else undefined.
	 * Point ds at the same page so the gdt pointer below can be
	 * reached; ss and es are set only so that nothing inherits a
	 * stale base, since nothing here pushes.
	 */
	movw	$(SMP_TRAMP_BASE >> 4), %ax
	movw	%ax, %ds
	xorw	%ax, %ax
	movw	%ax, %es
	movw	%ax, %ss

	/* the operand is in this page and is reached through ds; the
	 * table it names is the kernel's own gdt32, up at its link
	 * address, which is fine because lgdt takes a linear address
	 * and does not care that we cannot address it yet.
	 */
	lgdtl	TRAMP(gdt32_ptr16)

	movl	%cr0, %eax
	orl	$1, %eax		/* PE */
	movl	%eax, %cr0
	jmp	1f			/* the delay the mode switch wants */
1:

	/* the far jump that makes protected mode take effect. Encoded
	 * by hand: the assembler would build a 16-bit far jump here and
	 * the target is a 32-bit linear address up in the kernel.
	 */
	.byte	0x66, 0xea
	.long	smp_tramp32
	.word	0x08

	.globl	smp_tramp_end
smp_tramp_end:

/* from here on this is ordinary kernel text at its link address; the
 * copy at SMP_TRAMP_BASE is behind us and is read only for its two
 * handoff slots.
 */
	.section .text
	.code32
smp_tramp32:
	movw	$0x10, %ax
	movw	%ax, %ds
	movw	%ax, %es
	movw	%ax, %ss
	movw	%ax, %fs
	movw	%ax, %gs

	/* the same sequence entry_common runs, for the same reasons --
	 * see boot.S, including why SSE has to be enabled before any
	 * compiled code runs. The one difference is cr3, which loads
	 * the tables the BSP already built rather than building a
	 * second set.
	 */
	movl	%cr4, %eax
	orl	$0x000006a0, %eax	/* PAE|PGE|OSFXSR|OSXMMEXCPT */
	movl	%eax, %cr4

	movl	%cr0, %eax
	andl	$0xFFFFFFFB, %eax	/* clear EM */
	orl	$0x00000002, %eax	/* set MP */
	movl	%eax, %cr0

	movl	$pml4, %eax
	movl	%eax, %cr3

	movl	$0xC0000080, %ecx	/* EFER.LME */
	rdmsr
	orl	$0x00000100, %eax
	wrmsr

	movl	%cr0, %eax
	orl	$0x80000000, %eax	/* PG */
	movl	%eax, %cr0

	lgdt	gdt64_ptr
	ljmp	$0x08, $smp_tramp64

	.code64
smp_tramp64:
	movw	$0x10, %ax
	movw	%ax, %ds
	movw	%ax, %es
	movw	%ax, %ss
	movw	%ax, %fs
	movw	%ax, %gs

	xorw	%ax, %ax
	lldt	%ax			/* no ldt, and do not inherit one */

	/* the stack before anything that pushes, which popfq does:
	 * a SIPI leaves rsp holding whatever was in it at reset, and
	 * pushing onto that faults the cpu before it can report why.
	 */
	movq	(SMP_TRAMP_BASE + SMP_OFF_STACK), %rsp

	pushq	$0			/* flags: a known state, not the
					 * one a SIPI happened to leave */
	popfq

	movl	(SMP_TRAMP_BASE + SMP_OFF_INDEX), %edi
	xorq	%rbp, %rbp
	call	ap_main

	/* ap_main does not return; if it ever does, stop here rather
	 * than fall into whatever follows.
	 */
1:
	cli
	hlt
	jmp	1b

	.section .note.GNU-stack, "", @progbits
