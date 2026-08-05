/* IDT: 256 gates, all present. 0-31 (minus the timer vector) are the
 * fatal path from idt_stubs.S's generic table -- dump registers and
 * halt, so a fault is a loud, readable stop instead of a silent hang,
 * which is most of the reason for owning an IDT at all. the
 * LAPIC timer vector is the one exception: it must resume the
 * interrupted proc, so it gets its own entry point (isr_timer) wired
 * in by lapic_init(), not this file.
 */

#include <stdint.h>
#include <stdio.h>

#include "microvm.h"
#include "platform.h"

struct gate {
	uint16_t offset_lo;
	uint16_t selector;
	uint8_t  ist;
	uint8_t  type_attr;
	uint16_t offset_mid;
	uint32_t offset_hi;
	uint32_t reserved;
};

struct idtr {
	uint16_t limit;
	uint64_t base;
} __attribute__((packed));

#define NVEC 256
#define KCODE_SEL 0x08	/* see boot.S's GDT */

static struct gate idt[NVEC];

extern uint64_t isr_stub_table[NVEC];

struct trapframe {
	uint64_t r15, r14, r13, r12, r11, r10, r9, r8;
	uint64_t rbp, rdi, rsi, rdx, rcx, rbx, rax;
	uint64_t vector, errcode;
	uint64_t rip, cs, rflags, rsp, ss;
};

static void
set_gate(int n, uint64_t handler)
{
	idt[n].offset_lo = handler & 0xffff;
	idt[n].offset_mid = (handler >> 16) & 0xffff;
	idt[n].offset_hi = (handler >> 32) & 0xffffffff;
	idt[n].selector = KCODE_SEL;
	idt[n].ist = 0;
	idt[n].type_attr = 0x8E;	/* present, ring 0, 64-bit interrupt gate */
	idt[n].reserved = 0;
}

void
idt_set_vector(int n, void (*handler)(void))
{
	set_gate(n, (uint64_t)handler);
}

void
idt_init(void)
{
	for (int i = 0; i < NVEC; i++)
		set_gate(i, isr_stub_table[i]);
	idt_load();
}

/* point this cpu at the table. The table itself is one for the
 * machine and is filled in once by idt_init, but IDTR is a register
 * and every cpu has its own: an AP that never runs this has a null
 * one, and the first interrupt after it enables them is a fault it
 * has nowhere to deliver.
 */
void
idt_load(void)
{
	struct idtr idtr = {
		.limit = sizeof idt - 1,
		.base = (uint64_t)idt,
	};

	__asm__ volatile ("lidt %0" : : "m" (idtr));
}

static const char *
vecname(uint64_t v)
{
	static const char *names[32] = {
		"#DE divide error", "#DB debug", "NMI", "#BP breakpoint",
		"#OF overflow", "#BR bound range", "#UD invalid opcode",
		"#NM device not available", "#DF double fault", "reserved",
		"#TS invalid TSS", "#NP segment not present", "#SS stack fault",
		"#GP general protection", "#PF page fault", "reserved",
		"#MF x87 fp", "#AC alignment check", "#MC machine check",
		"#XM simd fp", "#VE virtualization", "#CP control protection",
		"reserved", "reserved", "reserved", "reserved", "reserved",
		"reserved", "reserved", "#HV hypervisor injection",
		"#VC vmm communication", "#SX security",
	};

	if (v < 32)
		return names[v];
	return "unknown";
}

/* every fault in this slice is fatal: print what happened and stop,
 * loudly, rather than the silent hang a wedged efi platform used to
 * produce with no idt at all. called only from trap_common
 * (idt_stubs.S); no other translation unit needs struct trapframe.
 */
_Noreturn void idt_dispatch(struct trapframe *tf);

_Noreturn void
idt_dispatch(struct trapframe *tf)
{
	char buf[256];

	console_write("\n--- trap ---\n", 14);
	snprintf(buf, sizeof buf, "vector %llu (%s) errcode %#llx\n",
	    (unsigned long long)tf->vector, vecname(tf->vector),
	    (unsigned long long)tf->errcode);
	console_write(buf, __builtin_strlen(buf));
	snprintf(buf, sizeof buf,
	    "rip %#llx cs %#llx rflags %#llx rsp %#llx ss %#llx\n",
	    (unsigned long long)tf->rip, (unsigned long long)tf->cs,
	    (unsigned long long)tf->rflags, (unsigned long long)tf->rsp,
	    (unsigned long long)tf->ss);
	console_write(buf, __builtin_strlen(buf));
	snprintf(buf, sizeof buf,
	    "rax %#llx rbx %#llx rcx %#llx rdx %#llx\n",
	    (unsigned long long)tf->rax, (unsigned long long)tf->rbx,
	    (unsigned long long)tf->rcx, (unsigned long long)tf->rdx);
	console_write(buf, __builtin_strlen(buf));
	snprintf(buf, sizeof buf,
	    "rsi %#llx rdi %#llx rbp %#llx\n",
	    (unsigned long long)tf->rsi, (unsigned long long)tf->rdi,
	    (unsigned long long)tf->rbp);
	console_write(buf, __builtin_strlen(buf));
	console_write("halted.\n", 8);
	machine_halt();
}
