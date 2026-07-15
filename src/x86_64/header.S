/* hand-rolled PE32+ header for x86_64 UEFI application.
 * linked at image base 0; firmware loads us anywhere and we
 * self-relocate in _start before calling efi_main.
 */

	.section .pe_header, "a"

/* DOS header */
dos_header:
	.ascii	"MZ"
	.fill	58, 1, 0
	.long	0x40			/* e_lfanew: PE header directly follows */

/* PE header */
pe_header:
	.ascii	"PE\0\0"

/* COFF file header */
	.short	0x8664			/* Machine: x86-64 */
	.short	2			/* NumberOfSections */
	.long	0			/* TimeDateStamp */
	.long	0			/* PointerToSymbolTable */
	.long	0			/* NumberOfSymbols */
	.short	opt_header_end - opt_header	/* SizeOfOptionalHeader */
	.short	0x0206			/* Characteristics: EXECUTABLE_IMAGE |
					   LINE_NUMS_STRIPPED | DEBUG_STRIPPED */

/* optional header, PE32+ */
opt_header:
	.short	0x020b			/* Magic: PE32+ */
	.byte	0			/* MajorLinkerVersion */
	.byte	0			/* MinorLinkerVersion */
	.long	0			/* SizeOfCode (unused by loader) */
	.long	0			/* SizeOfInitializedData */
	.long	0			/* SizeOfUninitializedData */
	.long	_start - dos_header	/* AddressOfEntryPoint (RVA) */
	.long	0x1000			/* BaseOfCode */
	.quad	0			/* ImageBase */
	.long	0x1000			/* SectionAlignment */
	.long	0x1000			/* FileAlignment */
	.short	0			/* MajorOperatingSystemVersion */
	.short	0			/* MinorOperatingSystemVersion */
	.short	0			/* MajorImageVersion */
	.short	0			/* MinorImageVersion */
	.short	0			/* MajorSubsystemVersion */
	.short	0			/* MinorSubsystemVersion */
	.long	0			/* Win32VersionValue */
	.long	__image_end - dos_header	/* SizeOfImage */
	.long	0x1000			/* SizeOfHeaders */
	.long	0			/* CheckSum */
	.short	10			/* Subsystem: EFI_APPLICATION */
	.short	0			/* DllCharacteristics */
	.quad	0			/* SizeOfStackReserve */
	.quad	0			/* SizeOfStackCommit */
	.quad	0			/* SizeOfHeapReserve */
	.quad	0			/* SizeOfHeapCommit */
	.long	0			/* LoaderFlags */
	.long	16			/* NumberOfRvaAndSizes */

/* data directories */
	.quad	0			/* export */
	.quad	0			/* import */
	.quad	0			/* resource */
	.quad	0			/* exception */
	.quad	0			/* certificate */
	.long	__reloc_start - dos_header	/* base relocation table RVA */
	.long	10			/* base relocation table size */
	.quad	0			/* debug */
	.quad	0			/* architecture */
	.quad	0			/* global ptr */
	.quad	0			/* TLS */
	.quad	0			/* load config */
	.quad	0			/* bound import */
	.quad	0			/* IAT */
	.quad	0			/* delay import */
	.quad	0			/* COM+ */
	.quad	0			/* reserved */
opt_header_end:

/* section table */
	.ascii	".text\0\0\0"
	.long	__reloc_start - dos_header - 0x1000	/* VirtualSize */
	.long	0x1000			/* VirtualAddress */
	.long	__reloc_start - dos_header - 0x1000	/* SizeOfRawData */
	.long	0x1000			/* PointerToRawData */
	.long	0			/* PointerToRelocations */
	.long	0			/* PointerToLinenumbers */
	.short	0			/* NumberOfRelocations */
	.short	0			/* NumberOfLinenumbers */
	.long	0xe0000060		/* Characteristics: CODE |
					   INITIALIZED_DATA | EXECUTE |
					   READ | WRITE */

	.ascii	".reloc\0\0"
	.long	10			/* VirtualSize */
	.long	__reloc_start - dos_header	/* VirtualAddress */
	.long	0x1000			/* SizeOfRawData */
	.long	__reloc_start - dos_header	/* PointerToRawData */
	.long	0			/* PointerToRelocations */
	.long	0			/* PointerToLinenumbers */
	.short	0			/* NumberOfRelocations */
	.short	0			/* NumberOfLinenumbers */
	.long	0x42000040		/* Characteristics: INITIALIZED_DATA |
					   READ | DISCARDABLE */

/* entry point.
 * firmware calls us ms_abi: RCX = EFI_HANDLE, RDX = EFI_SYSTEM_TABLE*.
 * self-relocate, then tail into efi_main(handle, systab) which is sysv.
 */
	.text
	.globl	_start
_start:
	pushq	%rcx
	pushq	%rdx
	subq	$8, %rsp

	leaq	__image_base(%rip), %rdi
	call	self_relocate

	addq	$8, %rsp
	popq	%rdx
	popq	%rcx

	movq	%rcx, %rdi
	movq	%rdx, %rsi
	jmp	efi_main

/* dummy base relocation block so the firmware does not reject us:
 * one empty block (page rva 0, size 10, one absolute entry).
 */
	.section .dummy_reloc, "a"
	.long	0			/* PageRVA */
	.long	10			/* BlockSize */
	.short	0			/* IMAGE_REL_BASED_ABSOLUTE */
