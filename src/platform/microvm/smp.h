#ifndef SMP_H
#define SMP_H

/* constants smp.c and smp_trampoline.S both need, and so the one
 * header here with no C in it.
 */

/* where the trampoline is copied to and where an AP begins executing.
 * The architecture allows any 4K page in the first megabyte -- a SIPI
 * carries an 8-bit vector and the cpu starts at vector << 12 -- and the
 * MP spec reserves vectors 0xA0 to 0xBF, so this is vector 8 and clear
 * of them.
 *
 * Nothing else may use this page. main.c's claim_memory never offers
 * the allocator anything below 0x100000, so there is no way for it to
 * be handed out, and no reservation is needed to keep it: the memory
 * below the kernel is unowned by construction rather than by agreement.
 */
#define SMP_TRAMP_BASE 0x8000

/* handoff slots inside that page, written by the BSP before each SIPI
 * and read by the AP once it is in long mode. Startup is one AP at a
 * time, so a single set of slots is enough and no atomic claim is
 * needed -- which is the reason to start them one at a time.
 */
#define SMP_OFF_STACK	0x08
#define SMP_OFF_INDEX	0x10

/* the limit for boot.S's gdt32, which is three descriptors. Spelled
 * out because the trampoline is a separate object and the assembler
 * cannot take the difference of two symbols it will only see at link
 * time; boot.S computes the same number from the labels themselves.
 */
#define SMP_GDT32_LIMIT	(3 * 8 - 1)

#endif
