/* plain ELF, loaded (and entered, via the PVH note) at a fixed
 * physical address -- no PE header, no self-relocation, unlike
 * src/platform/efi/pe.ld. qemu's -kernel loader for microvm reads
 * PT_LOAD segments for content and the PT_NOTE segment for the
 * XEN_ELFNOTE_PHYS32_ENTRY entry point (boot.S).
 *
 * e_entry is the other entry, entry_elf, for loaders that read the ELF
 * header instead of the note (OpenBSD vmd). qemu never looks at it.
 */
ENTRY(entry_elf)

PHDRS
{
	note PT_NOTE FLAGS(4);		/* R */
	text PT_LOAD FLAGS(5);		/* R+X */
	data PT_LOAD FLAGS(6);		/* R+W */
}

SECTIONS
{
	. = 0x100000;

	.note.pvh : { *(.note.pvh) } :note

	.text : {
		*(.text*)
	} :text

	.rodata : {
		*(.rodata*)
	} :text

	. = ALIGN(4096);

	.data : {
		*(.data*)
	} :data

	.bss : {
		__bss_start = .;
		*(.bss*)
		*(COMMON)
		__bss_end = .;
	} :data

	__image_end = .;

	/DISCARD/ : {
		*(.note.GNU-stack)
		*(.comment)
		*(.eh_frame)
	}
}
