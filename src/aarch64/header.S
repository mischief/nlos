/* hand-rolled PE32+ header for aarch64 UEFI application.
 * linked at image base 0; firmware loads us anywhere and we
 * self-relocate in _start before calling efi_main. identical to the
 * x86_64 header apart from the COFF Machine field and the entry stub.
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
	.short	0xaa64			/* Machine: aarch64 */
	.short	3			/* NumberOfSections */
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

/* section table.
 * two mapped sections, not one: code and rodata are RX, and everything
 * the relocation pass or the running kernel writes -- .data, .got,
 * .bss -- is a separate NX section, split at __data_start by
 * src/pe.ld. firmware with image protection enabled maps a writable
 * section non-executable, so an image whose one section claims both
 * cannot run there; AAVMF as shipped does not enforce that, and the
 * x86_64 header still gets away with a single RWX section. this is the
 * shape a UEFI image is supposed to have.
 * RVA and file offset are the same number throughout, since this is a
 * flat binary with FileAlignment == SectionAlignment.
 */
	.ascii	".text\0\0\0"
	.long	__data_start - dos_header - 0x1000	/* VirtualSize */
	.long	0x1000			/* VirtualAddress */
	.long	__data_start - dos_header - 0x1000	/* SizeOfRawData */
	.long	0x1000			/* PointerToRawData */
	.long	0			/* PointerToRelocations */
	.long	0			/* PointerToLinenumbers */
	.short	0			/* NumberOfRelocations */
	.short	0			/* NumberOfLinenumbers */
	.long	0x60000020		/* Characteristics: CODE |
					   EXECUTE | READ */

	.ascii	".data\0\0\0"
	.long	__data_size - dos_header	/* VirtualSize -- see pe.ld */
	.long	__data_start - dos_header	/* VirtualAddress */
	.long	__data_size - dos_header	/* SizeOfRawData */
	.long	__data_start - dos_header	/* PointerToRawData */
	.long	0			/* PointerToRelocations */
	.long	0			/* PointerToLinenumbers */
	.short	0			/* NumberOfRelocations */
	.short	0			/* NumberOfLinenumbers */
	.long	0xc0000040		/* Characteristics: INITIALIZED_DATA |
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
 * uefi on aarch64 is plain aapcs64, the same convention we compile to:
 * x0 = EFI_HANDLE, x1 = EFI_SYSTEM_TABLE*. so unlike x86_64 there is no
 * ms_abi shuffle -- just preserve the two arguments across the
 * relocation pass and fall into efi_main.
 */
	.text
	.globl	_start
	.type	_start, %function
_start:
	stp	x29, x30, [sp, #-32]!
	mov	x29, sp
	stp	x0, x1, [sp, #16]

	adrp	x0, __image_base	/* pc-relative: the load address */
	add	x0, x0, :lo12:__image_base
	bl	self_relocate

	ldp	x0, x1, [sp, #16]
	ldp	x29, x30, [sp], #32
	b	efi_main
	.size	_start, . - _start

/* dummy base relocation block so the firmware does not reject us:
 * one empty block (page rva 0, size 10, one absolute entry).
 */
	.section .dummy_reloc, "a"
	.long	0			/* PageRVA */
	.long	10			/* BlockSize */
	.short	0			/* IMAGE_REL_BASED_ABSOLUTE */
	.section .note.GNU-stack, "", %progbits
