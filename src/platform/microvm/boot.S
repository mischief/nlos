/* PVH entry (Xen's direct-boot ABI, which is what qemu's microvm/-kernel
 * ELF loading speaks): qemu finds the XEN_ELFNOTE_PHYS32_ENTRY note
 * below, loads this ELF's PT_LOAD segments at their physical addresses,
 * and jumps to that entry point in 32-bit protected mode with paging
 * off, ebx = phys addr of struct hvm_start_info. No firmware, no real
 * mode, no multiboot. main.c reads the memory map out of that struct;
 * see pvh.h for its layout.
 *
 * from there: build flat identity-mapped page tables covering the low
 * 4GB with 2MB pages (so 0xFEE00000/0xFEC00000 -- LAPIC/IOAPIC -- are
 * already mapped, with no separate MMIO-window bookkeeping needed),
 * enable PAE + long mode + paging, load a 64-bit GDT, far-jump into
 * 64-bit code, set up a stack, and call microvm_main(hvm_start_info).
 */

	.section .note.pvh, "", @note
	.align 4
pvh_note:
	.long	4			/* namesz */
	.long	4			/* descsz */
	.long	18			/* XEN_ELFNOTE_PHYS32_ENTRY */
	.ascii	"Xen\0"
	.long	entry32			/* desc: phys entry address */

	.section .bss
	.align 4096
pml4:		.skip 4096
pdpt:		.skip 4096
/* four contiguous 2MB-page PDs -- one alloc so build_pagetables' single
 * incrementing loop can fill all 2048 entries (4GB / 2MB) without
 * depending on the assembler/linker not padding between separate
 * labels.
 */
pds:		.skip 4 * 4096
pd0 = pds
pd1 = pds + 4096
pd2 = pds + 2 * 4096
pd3 = pds + 3 * 4096

	.align 16
boot_stack_bottom:
	.skip 65536
boot_stack_top:

	.section .rodata
	.align 16
gdt32:
	.quad	0			/* null */
	.quad	0x00cf9a000000ffff	/* 32-bit code, base 0, limit 4G */
	.quad	0x00cf92000000ffff	/* 32-bit data, base 0, limit 4G */
gdt32_end:

gdt32_ptr:
	.word	gdt32_end - gdt32 - 1
	.long	gdt32

	.align 16
gdt64:
	.quad	0			/* null */
	.quad	0x00af9a000000ffff	/* 64-bit code (L=1) */
	.quad	0x00cf92000000ffff	/* 64-bit data */
gdt64_end:

gdt64_ptr:
	.word	gdt64_end - gdt64 - 1
	.quad	gdt64

	.code32
	.section .text

/* the ELF header's e_entry, which is what a loader that does not read
 * the PVH note uses: OpenBSD vmd (usr.sbin/vmd/loadfile_elf.c) loads
 * PT_LOAD by p_paddr, zeroes bss, and jumps to e_entry in 32-bit
 * protected mode with paging off -- the same machine state PVH
 * specifies, minus the one thing PVH adds. There is no start_info and
 * ebx means nothing, so say so explicitly rather than let whatever the
 * loader left in it be dereferenced as a struct pointer; main.c's
 * claim_memory takes 0 as "no map" and falls back.
 *
 * Both entries can coexist because the two loaders look in different
 * places: qemu's microvm reads XEN_ELFNOTE_PHYS32_ENTRY and ignores
 * e_entry, vmd reads e_entry and ignores the note. One image boots
 * under both.
 */
	.globl	entry_elf
entry_elf:
	cli
	cld
	xorl	%ebx, %ebx
	jmp	entry_common

	.globl	entry32
entry32:
	cli
	cld

	/* ebx = hvm_start_info physaddr, per the PVH ABI -- stash it
	 * before it's clobbered; microvm_main gets it as its argument.
	 */
entry_common:
	movl	%ebx, pvh_start_info_ptr

	lgdt	gdt32_ptr
	ljmp	$0x08, $1f
1:
	movw	$0x10, %ax
	movw	%ax, %ds
	movw	%ax, %es
	movw	%ax, %ss
	movw	%ax, %fs
	movw	%ax, %gs

	movl	$boot_stack_top, %esp

	call	build_pagetables

	/* PAE + PGE + OSFXSR + OSXMMEXCPT: the last two are SSE, which
	 * nothing enables for us here (unlike EFI, where firmware already
	 * did it before jumping to efi_main) -- and -msse4.1 means the
	 * compiler emits movq/movups/pinsrq freely (e.g. malloc.c's header
	 * store), which #UD without them.
	 */
	movl	%cr4, %eax
	orl	$0x000006a0, %eax
	movl	%eax, %cr4

	/* CR0: clear EM (bit2, "no fpu/sse"), set MP (bit1) -- the other
	 * half of enabling SSE.
	 */
	movl	%cr0, %eax
	andl	$0xFFFFFFFB, %eax
	orl	$0x00000002, %eax
	movl	%eax, %cr0

	/* cr3 = pml4 */
	movl	$pml4, %eax
	movl	%eax, %cr3

	/* EFER.LME */
	movl	$0xC0000080, %ecx
	rdmsr
	orl	$0x00000100, %eax
	wrmsr

	/* enable paging (activates long mode: PG+PE+LME -> compat mode) */
	movl	%cr0, %eax
	orl	$0x80000000, %eax
	movl	%eax, %cr0

	lgdt	gdt64_ptr
	ljmp	$0x08, $long_mode_entry

/* fills pml4/pdpt/pd0-3 to identity-map 0-4GB with 2MB pages (PS=1).
 * PDE/PTE bit layout: bit0 P, bit1 R/W, bit7 PS.
 */
	.globl	build_pagetables
build_pagetables:
	/* pml4[0] = pdpt | P|RW */
	movl	$pdpt, %eax
	orl	$0x3, %eax
	movl	$pml4, %edx
	movl	%eax, (%edx)

	/* pdpt[0..3] = pd0..pd3 | P|RW */
	movl	$pd0, %eax
	orl	$0x3, %eax
	movl	$pdpt, %edx
	movl	%eax, 0(%edx)

	movl	$pd1, %eax
	orl	$0x3, %eax
	movl	%eax, 8(%edx)

	movl	$pd2, %eax
	orl	$0x3, %eax
	movl	%eax, 16(%edx)

	movl	$pd3, %eax
	orl	$0x3, %eax
	movl	%eax, 24(%edx)

	/* four PDs x 512 entries x 2MB = 4GB, PS|RW|P, base = i*2MB */
	movl	$pd0, %edi
	xorl	%eax, %eax
	movl	$2048, %ecx		/* 4 * 512 entries total */
	movl	$0x83, %ebx		/* P|RW|PS */
1:
	movl	%eax, (%edi)
	movl	$0, 4(%edi)		/* high dword: always 0 below 4G */
	orl	%ebx, (%edi)
	addl	$0x200000, %eax
	addl	$8, %edi
	loop	1b
	ret

	.code64
	.globl	long_mode_entry
long_mode_entry:
	movw	$0x10, %ax
	movw	%ax, %ds
	movw	%ax, %es
	movw	%ax, %ss
	movw	%ax, %fs
	movw	%ax, %gs

	movq	$boot_stack_top, %rsp
	xorq	%rbp, %rbp

	movl	pvh_start_info_ptr(%rip), %edi	/* zero-extends to 64 bits */
	call	microvm_main
1:
	hlt
	jmp	1b

	.section .bss
	.globl	pvh_start_info_ptr
pvh_start_info_ptr:
	.long	0

	.section .note.GNU-stack, "", @progbits
