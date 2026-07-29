/* no OUTPUT_FORMAT: gcc drives ld with the right emulation for
 * whichever arch it is compiling, and naming one here would only
 * contradict it.
 */
ENTRY(_start)

SECTIONS
{
	. = 0;
	__image_base = .;

	.header : {
		KEEP(*(.pe_header))
	}

	. = 0x1000;

	.text : {
		*(.text)
		*(.text.*)
	}

	.rodata : {
		*(.rodata)
		*(.rodata.*)
	}

	.rela : {
		__rela_start = .;
		*(.rela.dyn)
		*(.rela*)
		__rela_end = .;
	}

	.dynamic : { *(.dynamic) }
	.dynsym : { *(.dynsym) }
	.dynstr : { *(.dynstr) }
	.hash : { *(.hash) }
	.gnu.hash : { *(.gnu.hash) }

	/* everything above is read-only at runtime, everything below is
	 * written -- .got and the .data.rel.ro the relocations land in
	 * included. the page boundary here is what lets a PE header
	 * describe code and data as separate sections with separate
	 * permissions, instead of one section claiming both: firmware
	 * with image protection enabled maps a writable section
	 * non-executable, and a section that claims to be both then
	 * cannot run. neither AAVMF nor OVMF as shipped enforces that
	 * today, so this is hardening against stricter firmware rather
	 * than a fix for an observed fault -- but it is the shape a UEFI
	 * image is supposed to have, and both headers now use it.
	 */
	. = ALIGN(0x1000);
	__data_start = .;

	.data : {
		*(.data)
		*(.data.*)
		*(.got)
		*(.got.plt)
	}

	.bss : {
		*(.bss)
		*(.bss.*)
		*(COMMON)
	}

	. = ALIGN(0x1000);
	__reloc_start = .;

	.reloc : {
		KEEP(*(.dummy_reloc))
		/* pad to a full page so SizeOfRawData never points past EOF */
		. = ALIGN(0x1000);
	}

	. = ALIGN(0x1000);
	__image_end = .;

	
	

	/DISCARD/ : {
		*(.note*)
		*(.comment*)
		*(.eh_frame*)
	}
}

/* the PE section table needs this as a literal, and the assembler
 * cannot fold a difference between two symbols it never sees defined.
 * assigned out here, where ld makes it absolute.
 */
__data_size = __reloc_start - __data_start;
