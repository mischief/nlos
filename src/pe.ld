OUTPUT_FORMAT(elf64-x86-64)
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
