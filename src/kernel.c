/* mach-lite kernel: procs are isolated lua_States, ports are kernel
 * message queues, rights are per-proc handles onto ports. Lua sees no
 * pointers, and handle 0 is always a proc's own receive port. Preempted
 * on a count hook, so a busy loop cannot starve the machine.
 *
 * The dispatch loop and the device pumps live here. See docs/proc.md,
 * docs/ipc.md, docs/scheduling.md and docs/serialize.md.
 */

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "efi.h"
#include <sys/queue.h>

#include "kernel.h"
#include "kproc.h"
#include "serialize.h"
#include "timer.h"
#include "ksched.h"
#include "port.h"
#include "proc.h"
#include "sysapi.h"
#include "cpu.h"

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
#include "buf.h"
#include "luaheap.h"
#include "debug.h"
#include "platform.h"

/* MAXPROCS and MAXPORTS come from the platform's param.h: what is
 * headroom on a machine with gigabytes is a large share of a board's
 * ram. Ceilings, not reachable counts -- see docs/proc.md.
 */
#include "param.h"

#ifndef MAXPROCS
#error "platform param.h must define MAXPROCS"
#endif
#ifndef MAXPORTS
#error "platform param.h must define MAXPORTS"
#endif

/* floor on phase two's dispatch bound. The bound is what ends a lap at
 * all: two procs feeding each other hand phase two a fresh proc every
 * time it takes one. Sized to amortize the fixed cost between laps, not
 * merely to terminate -- see docs/scheduling.md.
 */
#define LAPSPILL	64

/* the console keyboard, pumped into a port whose receive right proc 0
 * holds. See docs/ipc.md on why each input device gets its own.
 */
static struct kport *kbdport;

/* the second terminal's keys, where the machine has a keyboard that is
 * not the console. Separate from kbdport: two terminals sharing one
 * input port race for every keystroke.
 */
static struct kport *devkbdport;

/* the pointer's events, where the machine has one. Its own port for the
 * same reason: two readers would each see half of a drag.
 */
static struct kport *devptrport;

/* the disk capability. A reserved port that carries no message: holding
 * any right to it is what fopen checks. It gates write and append only,
 * because a stray read corrupts nothing and the threat model is buggy
 * lua rather than a hostile user. See AGENTS.md on non-goals.
 */
struct kport *diskport;

/* the scheduling capability, same shape as diskport: a kernel-owned
 * port that is never sent to or received from. holding a right to it
 * is the authorization -- see api_set_priority.
 */
struct kport *schedport;

/* the clock capability, the same shape -- see api_settime. */
struct kport *clockport;

/* the debug capability, the same shape again. A right to it debugs any
 * proc, which is what reaches a boot service: nothing holds a right to
 * init's children but init.
 */
struct kport *dbgport;

extern unsigned long long platform_ticks(void);

/* the C heap's own accounting, per platform.
 *
 * Not named malloc_stats: that is a libc symbol, and a platform linking
 * a libc resolves it to one that takes no arguments and does nothing,
 * leaving the out-params holding whatever was on the stack. Nothing
 * warns, because the linker is happy to match the name.
 */
extern void kheap_stats(size_t *live, size_t *peak, unsigned long *blocks,
    unsigned long *total);

/* the eth task's wakeup, and the only device port here driven by an
 * interrupt rather than a poll. Pushed only when a device signals, so a
 * machine with a quiet wire sleeps instead of asking.
 */
static struct kport *ethport;
static struct kport *hciport;
static struct kport *gpsport;

/* the tcp task's wakeup, on the same terms as ethport: pushed when the
 * platform says a connection has something to answer, so a machine with
 * nothing outstanding sleeps rather than asking.
 */
static struct kport *netport;
static struct kport *udpport;

static int have_p9;
static int have_eth;
static int have_net;
static int have_udp;
static int have_ws;
static int have_hci;
static int have_gps;
static int have_fb;
static int have_lora;
static int have_blk;
static int have_flash;
static int have_wire;
static int have_esp;

/* when the wire was last drained. Every cpu runs procs and so reaches
 * the drain below, which made this a plain word two cpus wrote at once.
 * Atomic, and claimed by exchange rather than by two steps, so exactly
 * one cpu drains per window instead of however many arrive together.
 */
static atomic_ullong last_uart_drain;

/* time a known number of VM instructions and pick a hook period worth
 * about an eighth of a quantum. the loop body is a local increment, so
 * roughly two instructions per iteration (ADD, FORLOOP) -- the cheapest
 * realistic opcode mix, and therefore the worst case for a period
 * measured in instructions.
 */
static void
calibrate_reductions(void)
{
	lua_State *L = luaL_newstate();

	if (!L)
		return;

	static const char src[] =
	    "local x = 0 for _ = 1, 100000 do x = x + 1 end";

	if (luaL_loadstring(L, src) != LUA_OK) {
		lua_close(L);
		return;
	}

	unsigned long long t0 = platform_ticks();

	if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
		lua_close(L);
		return;
	}

	unsigned long long d = platform_ticks() - t0;

	lua_close(L);

	unsigned long long insns = 200000;	/* ~2 per iteration */
	unsigned long long cyc_per_insn = d / insns;

	if (cyc_per_insn == 0)
		cyc_per_insn = 1;

	unsigned long long target = (quantum_cycles / 8) / cyc_per_insn;

	/* keep it sane on absurdly fast or slow machines */
	if (target < 2000)
		target = 2000;
	if (target > 500000)
		target = 500000;
	default_reductions = (int)target;
}

extern void console_write(const char *s, size_t n);
void luaL_openlibs(lua_State *L);	/* our linit */

void
kputs(const char *s)
{
	console_write(s, strlen(s));
}

/* the transcript, in the kernel because the earliest producers are here
 * and because a task can die. A cursor is logseq -- bytes ever written,
 * not a ring offset -- so a reader that fell behind is told what it lost.
 */
#define LOGRING	(32 * 1024)
#define LOGEARLY 1024		/* until there is an allocator to ask */
#define LOGCHUNK 2048		/* the most one sys.dmesg call copies */

static char logearly[LOGEARLY];
static char *logring = logearly;
static size_t logsize = LOGEARLY;
static unsigned long long logseq;	/* bytes ever written */
static unsigned long long loglost;	/* bytes overwritten unread */
static struct lock loglock = LOCK_INIT;

static unsigned long long
logoldest(void)
{
	return logseq > logsize ? logseq - logsize : 0;
}

/* Nothing in here may log: the gc error path calls kernel_log, and a
 * second entry with the lock held would sit on itself forever.
 */
void
logput(const char *s, size_t n)
{
	if (n == 0)
		return;
	if (n > logsize) {		/* LOGLINE bounds every caller */
		s += n - logsize;
		n = logsize;
	}
	lock(&loglock);

	unsigned long long before = logoldest();
	size_t w = (size_t)(logseq % logsize);
	size_t first = logsize - w < n ? logsize - w : n;

	memcpy(logring + w, s, first);
	if (first < n)
		memcpy(logring, s + first, n - first);
	logseq += n;
	loglost += logoldest() - before;
	unlock(&loglock);
}

/* Off the static array as soon as there is an allocator to ask. On a
 * board this is tens of KB of the scarcest memory there is, and
 * platform_chunk_alloc answers from PSRAM where the machine has some.
 * Byte by byte because a position in a ring is modulo its size, so
 * every retained byte moves: see logoldest.
 */
static void
loginit(void)
{
	char *p = platform_chunk_alloc(LOGRING);

	if (!p)
		return;

	lock(&loglock);

	unsigned long long i;

	for (i = logoldest(); i < logseq; i++)
		p[i % LOGRING] = logring[i % logsize];
	logring = p;
	logsize = LOGRING;
	unlock(&loglock);
}

/* one stamped diagnostic line, terminated here so callers cannot forget.
 *
 * the format is shared with lib/log.lua: two producers, one transcript.
 * the stamp is taken when the line is emitted, which matters because a
 * proc reaching the console through a port is delivered later than this
 * synchronous path -- so display order and real order differ, and only
 * the stamps recover it.
 */
/* whether a diagnostic is echoed to the console as well as kept. Off
 * while the console carries something that is not text: a transfer
 * reads every byte as protocol, so a line about dhcp lands in the
 * middle of a file. The ring keeps it either way.
 */
int logmirror = 1;

static void
klogfmt(const char *s, int loud)
{
	unsigned long long ms = uptime_ms();
	char buf[320];
	int n = snprintf(buf, sizeof buf, "[%5llu.%03llu] %s\n", ms / 1000,
	    ms % 1000, s);

	if (loud && logmirror)
		kputs(buf);
	logput(buf, n < 0 ? 0 : (size_t)n >= sizeof buf ? sizeof buf - 1 :
	    (size_t)n);
}

/* the kernel's own halves of sys.log and sys.say, and the same bargain:
 * log keeps, say keeps and shows.
 */
void
kernel_log(const char *s)
{
	klogfmt(s, 0);
}

void
kernel_say(const char *s)
{
	klogfmt(s, 1);
}

/* ---- ports and rights ---- */

/* the los.sys module: the microkernel abi (ports, rights, procs) plus
 * kernel-owned primitives that outlive efi (ticks). registered in
 * package.preload by proc_new; a chunk pulls it in with an explicit
 * require("los.sys"). the proc pointer comes from the state's extra
 * space, so the api needs no upvalues.
 */

/* los.thread lives in src/thread.c. */
int luaopen_los_thread(lua_State *L);

/* print(), for a proc that has not redirected it. See src/coreg.h: this
 * is what lua_writestring becomes, so an unredirected diagnostic
 * reaches the console rather than a stdio that may discard it.
 */
void
kernel_stdout(const char *s, size_t n)
{
	console_write(s, n);
}

/* build and deliver an exit notification: {exit=pid, normal=bool,
 * reason=string?, broke=true?} to the watcher's self port. broke=true
 * arrives while the corpse is still held, so a watcher can read the
 * stack of the pid it was just told about, and reap it when done.
 */

/* ---- serial pump (9p wire on com2) ---- */

extern void uart_init(void);
extern int uart_rx(void);
extern void uart_poll(void);	/* drain the hw fifo into the rx ring */

static struct kport *serport;

static int
pump_serial(void)
{
	unsigned char buf[5 + 256];
	unsigned int n = 0;
	int c;

	/* the console claimed these bytes; pump_keyboard takes them
	 * instead. One uart cannot feed two readers, and taking them here
	 * first is exactly how the console got no input at all.
	 */
	if (platform_console_input())
		return 0;

	while (n < 256 && (c = uart_rx()) >= 0)
		buf[5 + n++] = (unsigned char)c;
	if (n == 0)
		return 0;
	/* serialized string message: tag, u32 len, bytes */
	buf[0] = 'S';
	memcpy(buf + 1, &n, 4);
	ipclock_enter();
	port_push(serport, buf, 5 + n, 0, 0);
	ipclock_leave();
	return 1;
}

/* ---- eth pump ---- */

/* the eth wakeup: push only when a device interrupt has been taken
 * since the last look.
 *
 * Coalesced by the emptiness check, so a burst of frames is one wakeup
 * rather than one per frame -- the task drains what is there when it
 * runs, and a second ping while the first is unread would tell it
 * nothing new.
 */
static void
pump_eth(void)
{
	static unsigned long seen;
	unsigned long now = platform_dev_irqs();

	if (now == seen)
		return;
	seen = now;
	/* "N" is a serialized nil, which is what this has to be: a port
	 * carries serialized values, and the
	 * receiving task deserializes whatever arrives. A byte chosen to
	 * be mnemonic instead of valid ("E", the first try) reaches the
	 * task as a corrupt message and kills it. The wakeup carries no
	 * information anyway -- the frames are still in the device's
	 * queue, and this says only "ask again".
	 */
	ipclock_enter();
	if (have_eth && ethport && !atomic_load_explicit(&ethport->head, memory_order_relaxed))
		port_push(ethport, (const unsigned char *)"N", 1, 0, 0);
	ipclock_leave();
}

/* the tcp task's wakeup, on pump_eth's terms and for the same reason.
 * platform_net_ready answers only when an outstanding operation can
 * make progress, so a machine whose connections are all quiet sleeps.
 */
static void
pump_net(void)
{
	if (!have_net && !have_udp)
		return;
	/* one readiness question for both: it answers for every
	 * outstanding operation, so a udp datagram wakes the tcp task
	 * too. That task finds nothing and blocks again, which is one
	 * spare wakeup rather than a second poll of every socket.
	 */
	if (!platform_net_ready())
		return;
	/* the queue is read under the lock that writes it, as pump_eth
	 * reads its own: port_push_owned sets head with the port's bucket
	 * held, so asking from outside races every send.
	 */
	ipclock_enter();
	if (have_net && netport && !atomic_load_explicit(&netport->head, memory_order_relaxed))
		port_push(netport, (const unsigned char *)"N", 1, 0, 0);
	if (have_udp && udpport && !atomic_load_explicit(&udpport->head, memory_order_relaxed))
		port_push(udpport, (const unsigned char *)"N", 1, 0, 0);
	ipclock_leave();
}

/* ---- hci pump ---- */

/* the same wakeup pump_eth is, on its own counter: an HCI packet and an
 * ethernet frame arrive by different paths, and one must not be woken
 * for the other's traffic.
 */
static void
pump_hci(void)
{
	static unsigned long seen;
	unsigned long now = platform_hci_irqs();

	if (now == seen)
		return;
	seen = now;
	ipclock_enter();
	if (have_hci && hciport && !atomic_load_explicit(&hciport->head, memory_order_relaxed))
		port_push(hciport, (const unsigned char *)"N", 1, 0, 0);
	ipclock_leave();
}

/* ---- gps pump ---- */

/* a receiver emits once a second and the task waits between, so
 * something has to say that bytes have landed. What is waiting rather
 * than what was taken: a count of our own reads could only rise after
 * a read, and the read is what this wakeup exists to cause.
 */
static void
pump_gps(void)
{
	if (!have_gps || !gpsport || platform_gps_pending() == 0)
		return;
	ipclock_enter();
	if (!atomic_load_explicit(&gpsport->head, memory_order_relaxed))
		port_push(gpsport, (const unsigned char *)"N", 1, 0, 0);
	ipclock_leave();
}

/* ---- keyboard pump ---- */

/* the firmware's serial console reports the arrow/navigation keys and the
 * Escape key as ScanCodes with UnicodeChar 0, having already parsed the
 * ANSI sequences a byte terminal sends. A full-screen program (bin/vi.lua)
 * wants those bytes, so turn the ScanCodes back into the sequences -- the
 * exact inverse of what the firmware did, so vi sees what it would see on
 * a raw serial line. Values are the UEFI spec's (table "EFI Scan Codes");
 * SCAN_DELETE (physical Backspace under OVMF) is handled separately below
 * and deliberately absent here. Returns 0 for a ScanCode with no mapping,
 * including the 0 that a raw serial shim (microvm) always reports.
 */
static const char *
scancode_seq(unsigned scan)
{
	switch (scan) {
	case 0x17: return "\033";	/* Esc */
	case 0x01: return "\033[A";	/* Up */
	case 0x02: return "\033[B";	/* Down */
	case 0x03: return "\033[C";	/* Right */
	case 0x04: return "\033[D";	/* Left */
	case 0x05: return "\033[H";	/* Home */
	case 0x06: return "\033[F";	/* End */
	case 0x09: return "\033[5~";	/* PageUp */
	case 0x0a: return "\033[6~";	/* PageDown */
	case 0x07: return "\033[2~";	/* Insert */
	default:   return 0;
	}
}

/* how many keystrokes one message may carry. Bounded because the
 * message is a stack buffer and a reader wants its keys promptly.
 */
#define KBDBATCH 256

/* drain the second terminal's keyboard into its own port.
 *
 * The same shape as pump_keyboard below, and deliberately not the same
 * port: this machine's console is a serial line, and a panel with a
 * keyboard is a second terminal rather than a second way into the
 * first.
 */
static void
pump_devkbd(void)
{
	int c;

	if (!devkbdport)
		return;

	/* Read first, so a lap with no key takes no lock: the scheduler
	 * calls this on every pass.
	 */
	c = platform_kbd_read();
	if (c < 0)
		return;

	/* serialized string, as pump_keyboard sends. One message per drain
	 * rather than per key, because an arrow is the three bytes ESC [ A:
	 * a reader given them one at a time sees a bare ESC, and every
	 * program treating that as "leave" quits on an arrow.
	 */
	unsigned char msg[5 + KBDBATCH];
	size_t n = 0;

	msg[0] = 'S';

	/* Every bucket, because port_push asks for that: it carries
	 * IPC_ASSERT_LOCKED, which is the whole-lock demand, not
	 * IPC_ASSERT_PORT. Narrowing this means narrowing port_push
	 * first. Held across the drain.
	 */
	ipclock_enter();
	do {
		msg[5 + n++] = (unsigned char)c;
	} while (n < KBDBATCH && (c = platform_kbd_read()) >= 0);

	/* all four length bytes, so the header does not depend on the
	 * initializer having zeroed the two a small batch leaves alone
	 */
	msg[1] = (unsigned char)(n & 0xff);
	msg[2] = (unsigned char)((n >> 8) & 0xff);
	msg[3] = (unsigned char)((n >> 16) & 0xff);
	msg[4] = (unsigned char)((n >> 24) & 0xff);
	port_push(devkbdport, msg, 5 + n, 0, 0);
	ipclock_leave();
}

/* the pointer, onto its own port. What goes out is plan 9's mouse
 * record: 'm' and four fixed-width fields -- x, y, buttons, and a
 * millisecond clock. Fixed width so a reader asks for one record's
 * worth and gets exactly one event, needing no framing rule of its own.
 *
 * The driver coalesces, so this pushes at most one message per lap and
 * that message is the current state.
 */
static void
pump_devptr(void)
{
	int x = 0, y = 0, b = 0;
	char rec[64];
	int n;

	if (!devptrport)
		return;
	if (!platform_ptr_read(&x, &y, &b))
		return;

	/* four fields of twelve -- a space and eleven digits -- after the
	 * 'm', which is 49 bytes. The width is the framing rule, so a
	 * record of another size is a record no reader can trust.
	 */
	n = snprintf(rec, sizeof rec, "m%12d%12d%12d%12d",
	    x, y, b, (int)(platform_ticks() / 1000));
	if (n != 49)
		return;

	/* a serialized string, as the keyboard pump sends: 'S', the
	 * length, then the bytes.
	 */
	{
		unsigned char msg[5 + sizeof rec];
		int i;

		msg[0] = 'S';
		msg[1] = (unsigned char)(n & 0xff);
		msg[2] = (unsigned char)((n >> 8) & 0xff);
		msg[3] = (unsigned char)((n >> 16) & 0xff);
		msg[4] = (unsigned char)((n >> 24) & 0xff);
		for (i = 0; i < n; i++)
			msg[5 + i] = (unsigned char)rec[i];

		/* every bucket, as pump_devkbd takes: port_push carries
		 * IPC_ASSERT_LOCKED.
		 */
		ipclock_enter();
		port_push(devptrport, msg, (size_t)(5 + n), 0, 0);
		ipclock_leave();
	}
}
/* What the console has not taken yet. A full queue means the reader is
 * behind, and dropping loses the middle of a file: hold the batch and
 * stop reading the device, so the sender waits instead. One buffer for
 * the machine is enough -- only the boot cpu pumps devices, as
 * kernel_run_ap says.
 */
static unsigned char kbdheld[5 + KBDBATCH];
static size_t kbdheldn;

static int
kbdflush(unsigned char *msg, size_t *n)
{
	msg[1] = (unsigned char)(*n & 0xff);
	msg[2] = (unsigned char)((*n >> 8) & 0xff);
	msg[3] = 0;
	msg[4] = 0;
	if (port_push(kbdport, msg, 5 + *n, 0, 0) == -2) {
		memcpy(kbdheld, msg, 5 + *n);
		kbdheldn = *n;
		*n = 0;
		return 0;
	}
	*n = 0;
	return 1;
}

/* the held batch, if any. Zero means it still does not fit, and the
 * caller must not read more.
 */
static int
kbddrain(void)
{
	size_t n = kbdheldn;

	if (n == 0)
		return 1;
	if (port_push(kbdport, kbdheld, 5 + n, 0, 0) == -2)
		return 0;
	kbdheldn = 0;
	return 1;
}

static void
pump_keyboard(void)
{
	EFI_INPUT_KEY key;

	if (kbdheldn) {
		int ok;

		ipclock_enter();
		ok = kbddrain();
		ipclock_leave();
		if (!ok)
			return;
	}

	/* Poll before locking: the scheduler calls this every lap and
	 * nearly every lap has no key, where taking the lock is the whole
	 * cost of the call.
	 */
	if (ST->ConIn->ReadKeyStroke(ST->ConIn, &key) != EFI_SUCCESS)
		return;

	/* serialized string: tag, u32 len, bytes. One message per drain
	 * rather than per byte -- a keyboard never fills it, and a serial
	 * line carrying a file measured 440ms per 1024-byte subpacket when
	 * every byte cost a message and a receive.
	 */
	unsigned char msg[5 + KBDBATCH] = { 'S', 0, 0, 0, 0 };
	size_t n = 0;
	int full = 0;

	ipclock_enter();
	do {
		/* the physical Backspace key arrives as ScanCode=SCAN_DELETE,
		 * UnicodeChar=0 under OVMF (confirmed by direct trace), not
		 * as CHAR_BACKSPACE -- map it to DEL (0x7f), which cons.lua's
		 * readline already treats the same as Ctrl-H/0x08.
		 */
		if (key.ScanCode == SCAN_DELETE && key.UnicodeChar == 0) {
			msg[5 + n++] = 0x7f;
		} else if (key.UnicodeChar == 0) {
			/* a non-unicode key: an arrow, Escape and the like,
			 * as the ANSI sequence a raw serial line would send.
			 */
			const char *seq = scancode_seq(key.ScanCode);
			size_t len = 0;

			while (seq && seq[len])
				len++;
			/* the whole sequence or none of it. Half an escape
			 * is not a shorter escape -- it reaches the editor
			 * as Escape followed by rubbish, and the rubbish is
			 * whatever letter the arrow ended with.
			 */
			if (len > 0 && n + len > KBDBATCH)
				full = !kbdflush(msg, &n);
			if (!full) {
				for (size_t k = 0; k < len; k++)
					msg[5 + n++] = (unsigned char)seq[k];
			}
		} else if (key.UnicodeChar <= 0xff) {
			/* 0x80..0xff is a byte, not a character to judge: on
			 * a serial line this is a raw octet and a binary
			 * stream is half made of them. Only a wide character,
			 * which no byte source produces, has nowhere to go.
			 */
			msg[5 + n++] = (unsigned char)key.UnicodeChar;
		}
		if (n == KBDBATCH)
			full = !kbdflush(msg, &n);
	} while (!full &&
	    ST->ConIn->ReadKeyStroke(ST->ConIn, &key) == EFI_SUCCESS);
	if (n)
		kbdflush(msg, &n);
	ipclock_leave();
}

/* ---- kernel ---- */

int
kernel_init(void)
{
	loginit();		/* while the boot lines are still few */
	calibrate_reductions();	/* kernel_clock_init already ran in efi_main */
	rq_init();		/* before any proc exists to be dispatched */
	uart_init();
	/* boot, before any proc exists: the lock is uncontended and is
	 * taken for the contract rather than for the contention.
	 */
	ipclock_enter();
	kbdport = port_new();
	devkbdport = platform_have_kbd() ? port_new() : 0;
	devptrport = platform_have_ptr() ? port_new() : 0;
	serport = port_new();
	diskport = port_new();
	ethport = port_new();
	hciport = port_new();
	gpsport = port_new();
	netport = port_new();
	udpport = port_new();
	schedport = port_new();
	clockport = port_new();
	dbgport = port_new();
	ipclock_leave();
	if (!kbdport || !serport || !diskport || !schedport || !ethport ||
	    !netport || !udpport || !clockport || !dbgport)
		return -1;
	/* kernel refs: the pumps (and, for diskport/schedport, the kernel
	 * itself) hold these ports forever
	 */
	kbdport->nrights++;
	if (devkbdport)
		devkbdport->nrights++;
	if (devptrport)
		devptrport->nrights++;
	serport->nrights++;
	diskport->nrights++;
	ethport->nrights++;
	hciport->nrights++;
	if (gpsport)
		gpsport->nrights++;
	netport->nrights++;
	udpport->nrights++;
	schedport->nrights++;
	clockport->nrights++;
	dbgport->nrights++;

	/* soft-fail: no card means no eth task is spawned later, like any
	 * other optional boot-time resource.
	 *
	 * On efi this unbinds the firmware's own network stack from the
	 * card, and has to: SNP has one receive queue and no fan-out, so a
	 * stack left bound eats frames we never see. There is nothing to
	 * fall back to -- one stack, ours, on every platform.
	 */
	have_eth = platform_have_eth();
	have_net = platform_have_net();
	have_udp = platform_have_udp();
	have_ws = platform_have_ws();
	have_hci = platform_have_hci();
	have_gps = platform_have_gps();
	have_p9 = platform_have_p9();
	have_fb = platform_have_fb();
	have_lora = platform_have_lora();
	have_blk = platform_have_blk();
	have_flash = platform_have_flash();
	have_wire = platform_have_wire();
	have_esp = platform_have_esp();
	return 0;
}

/* spawn a privileged driver task and grant it whatever raw device
 * right it needs directly (handle 1, right after the universal
 * self-port at 0). returns its pid, or -1 with a boot warning; the
 * corresponding resource is simply unreachable for the rest of that
 * boot if its task fails to start.
 */
static int
spawn_driver(const char *path, const char *chunkname, int priv,
    struct kport *devport, int devrecv, const char *what)
{
	/* caller holds ipclock: spawn_init calls this in a loop and
	 * holds it across all of them.
	 */
	int pid = proc_new(path, 0, chunkname, 1, 0, 0, 0, priv);
	char buf[160];

	if (pid < 0) {
		snprintf(buf, sizeof buf,
		    "%s: FAILED to start; %s unavailable this boot",
		    chunkname + 1, what);
		kernel_say(buf);
		return -1;
	}
	/* the device right first, then run it: the task cannot do its job
	 * without it.
	 */
	struct kproc *p = find_proc(pid);

	if (p) {
		if (devport)
			right_new(p, devport, devrecv);
		proc_launch(p);
	}

	/* announce what attached, the way a bsd announces its devices.
	 * these tasks ARE our device layer -- one proc per raw right -- and
	 * the pid is the part you cannot recover later without a shell,
	 * which is exactly when you have not got one.
	 */
	snprintf(buf, sizeof buf, "%s: pid %d, %s", chunkname + 1, pid, what);
	kernel_say(buf);
	return pid;
}

/* one row per driver task the boot payload gets a right to. Whether a
 * row is enabled is decided by the probes in kernel_init, before this
 * table is built: a one-shot boot-time table, not a runtime bus and
 * match-and-attach registry. Disk and sched are not here, having no
 * owner task -- they are bare capability ports granted to init.
 */
struct driver_desc {
	const char *path;
	const char *chunkname;
	int priv;
	struct kport *devport;
	int devrecv;
	const char *what;
	int enabled;
	const char *capname;	/* what sys.granted() calls it */

};

static int
spawn_init(const char *code, size_t len, int is_file)
{
	struct driver_desc drivers[] = {
		{ .path = "/task/cons.lua", .chunkname = "=cons",
		  .priv = PRIV_CONS, .devport = kbdport, .devrecv = 1,
		  .what = "console", .enabled = 1, .capname = "cons" },
		{ .path = "/task/wire.lua", .chunkname = "=wire",
		  .priv = PRIV_WIRE, .devport = serport, .devrecv = 1,
		  .what = "the 9p wire", .enabled = have_wire,
		  .capname = "wire" },
		/* the esp server: the only proc that reaches the disk
		 * directly. it gets diskport at handle 1, so writes are
		 * possible here and nowhere else.
		 */
		{ .path = "/task/espsrv.lua", .chunkname = "=esp",
		  .priv = PRIV_ESP, .devport = diskport, .devrecv = 0,
		  .what = "the esp filesystem", .enabled = have_esp,
		  .capname = "esp" },
		{ .path = "/task/power.lua", .chunkname = "=power",
		  .priv = PRIV_POWER, .devport = 0, .devrecv = 0,
		  .what = "reset/stall", .enabled = 1, .capname = "power" },
		/* the virtio-9p mount source: the only proc with
		 * los.platform.p9, re-serving it over a port as an
		 * ordinary dev backend (lib/p9fs.lua) so mnt.lua can mount
		 * it exactly like the esp -- no second namespace mechanism,
		 * just another srv.lua backend. disabled on efi today
		 * because that driver only speaks virtio-MMIO, not because
		 * virtio-9p can't exist under EFI -- see platform_have_p9's
		 * own comment in platform.h.
		 */
		{ .path = "/task/p9srv.lua", .chunkname = "=p9srv",
		  .priv = PRIV_P9, .devport = 0, .devrecv = 0,
		  .what = "the virtio-9p filesystem", .enabled = have_p9,
		  .capname = "p9" },
		/* the block device: the only proc with los.platform.blk,
		 * re-serving it over a port. Unlike every other backend
		 * here, what it serves is not a filesystem but one file,
		 * /data, that is the disk. Whatever reads a filesystem out
		 * of those bytes mounts this and knows nothing of virtio.
		 *
		 * No devport: nothing routes this device's interrupt, so
		 * there is no wakeup to deliver, and its reads and writes
		 * yield and re-poll instead.
		 */
		{ .path = "/task/blksrv.lua", .chunkname = "=blksrv",
		  .priv = PRIV_BLK, .devport = 0, .devrecv = 0,
		  .what = "the block device", .enabled = have_blk,
		  .capname = "blk" },
		/* the writable flash, as a filesystem. The proc doing the
		 * filesystem owns the device, so a sector is a call and not
		 * a message, and there is no block server between them.
		 */
		/* the flash and the card both, where there is a card: two
		 * devices in one proc because the alternative is a second
		 * copy of lib/fat, which is the larger cost of the two on
		 * a board whose ceiling is memory. los.platform.blk says
		 * for itself whether a card answered.
		 */
		{ .path = "/task/fatsrv.lua", .chunkname = "=fatsrv",
		  .priv = PRIV_FLASH | PRIV_BLK, .devport = 0, .devrecv = 0,
		  .what = "the flash filesystem", .enabled = have_flash,
		  .capname = "flash" },
		/* raw ethernet frames, and the bottom of the whole stack.
		 * This task owns a wire and nothing more -- everything from
		 * arp upwards is Lua on the far side of its port. No NIC
		 * (real hardware, or qemu -net none) is the normal case
		 * rather than a boot failure, so it and everything needing
		 * it simply do not spawn.
		 */
		{ .path = "/task/eth.lua", .chunkname = "=eth",
		  .priv = PRIV_ETH, .devport = ethport, .devrecv = 1,
		  .what = "networking (raw ethernet)", .enabled = have_eth,
		  .capname = "eth" },
		/* the bluetooth controller, HCI packets and no more. Same
		 * arrangement as the wire above it: this task owns the
		 * transport, and GAP, L2CAP, ATT and GATT are Lua on the
		 * far side of its port.
		 */
		{ .path = "/task/hci.lua", .chunkname = "=hci",
		  .priv = PRIV_HCI, .devport = hciport, .devrecv = 1,
		  .what = "bluetooth (raw hci)", .enabled = have_hci,
		  .capname = "hci" },
		/* the gnss receiver: bytes off a serial port, and the
		 * sentences in them read on the far side of this task's
		 * port. Present on a board that could carry a module,
		 * whether or not one is fitted -- only its answers say.
		 */
		{ .path = "/task/gpsd.lua", .chunkname = "=gpsd",
		  .priv = PRIV_GPS, .devport = gpsport, .devrecv = 1,
		  .what = "the gnss receiver", .enabled = have_gps,
		  .capname = "gps" },
		/* tcp from the machine rather than from lib/tcp4.lua: a
		 * platform with connections but no frames to build them out
		 * of. Everything above holds a right to this task and cannot
		 * tell which stack answered, which is what lets one machine
		 * take the protocol from below and another build it in Lua.
		 */
		{ .path = "/task/tcp.lua", .chunkname = "=tcp",
		  .priv = PRIV_TCP, .devport = netport, .devrecv = 1,
		  .what = "networking (tcp from the host)",
		  .enabled = have_net, .capname = "tcp" },
		/* udp on the same terms, and its own task: a proc that
		 * resolves names holds this and not the other.
		 */
		{ .path = "/task/udp.lua", .chunkname = "=udp",
		  .priv = PRIV_UDP, .devport = udpport, .devrecv = 1,
		  .what = "networking (udp from the host)",
		  .enabled = have_udp, .capname = "udp" },
		/* websockets, on a machine that has them and nothing under
		 * them. No devport: a socket is polled rather than routed,
		 * for the same reason blksrv has none.
		 */
		{ .path = "/task/wssrv.lua", .chunkname = "=wssrv",
		  .priv = PRIV_WS, .devport = 0, .devrecv = 0,
		  .what = "networking (websockets from the host)",
		  .enabled = have_ws, .capname = "ws" },
		/* ip, tcp4 and dhcp are not here. Each owns no device and
		 * holds only a send right to the task below it, so they
		 * come off the filesystem, started from a machine's
		 * /etc/services.lua.
		 */

		/* the framebuffer. no devport: unlike the console or the
		 * wire there is nothing to poll -- a screen produces no
		 * events, and the input devices that go with one are
		 * already somebody else's capability. so this task only
		 * ever receives from procs holding a right to it.
		 */
		{ .path = "/task/fb.lua", .chunkname = "=fb",
		  .priv = PRIV_FB, .devport = 0, .devrecv = 0,
		  .what = "the framebuffer", .enabled = have_fb,
		  .capname = "fb" },
		/* the LoRa radio. No devport: the chip says a packet is
		 * done on a pin this task reads, so there is no interrupt
		 * for the kernel to turn into a message.
		 */
		{ .path = "/task/lora.lua", .chunkname = "=lora",
		  .priv = PRIV_LORA, .devport = 0, .devrecv = 0,
		  .what = "the lora radio", .enabled = have_lora,
		  .capname = "lora" },
	};
	size_t ndrivers = sizeof drivers / sizeof drivers[0];
	int pids[sizeof drivers / sizeof drivers[0]];
	size_t i;

	/* one region over the whole of boot's proc and port creation.
	 * spawn_driver, proc_new and grant_named are all caller-holds,
	 * and holding it across the lot is free here: nothing else is
	 * running yet, and the alternative is acquiring and releasing
	 * once per driver for no benefit.
	 */
	ipclock_enter();
	for (i = 0; i < ndrivers; i++) {
		if (!drivers[i].enabled) {
			char skip[160];

			snprintf(skip, sizeof skip, "%s: not present, %s "
			    "unavailable this boot",
			    drivers[i].chunkname + 1, drivers[i].what);
			kernel_say(skip);
			pids[i] = -1;
			continue;
		}
		pids[i] = spawn_driver(drivers[i].path, drivers[i].chunkname,
		    drivers[i].priv, drivers[i].devport, drivers[i].devrecv,
		    drivers[i].what);

	}

	int pid = proc_new(code, len, "=init", is_file, 0, 0, 0, PRIV_BOOT);

	if (pid < 0) {
		ipclock_leave();
		return pid;
	}

	struct kproc *p = find_proc(pid);

	/* platform_boot_extra_modules grants whatever raw device modules
	 * have no driver-task equivalent yet (microvm's los.platform.rng/
	 * p9 -- see src/platform/microvm/drivers.c); a no-op on efi.
	 */
	if (p)
		platform_boot_extra_modules(p->L);

	/* handles are allocated first-free, in this order, and reported
	 * by name through sys.granted(). nothing anywhere depends on the
	 * numbers: a driver that was disabled or failed to spawn simply
	 * doesn't appear in the mapping, and everything after it shifts
	 * down a slot harmlessly.
	 */
	for (i = 0; i < ndrivers; i++) {
		struct kproc *dp = pids[i] >= 0 ? find_proc(pids[i]) : 0;

		if (dp)
			grant_named(p, drivers[i].capname,
			    dp->rights[0].port, 0);
	}
	/* a receive right: whoever init hands this to IS the second
	 * terminal's keyboard, and there is only one of it.
	 */
	if (devkbdport)
		grant_named(p, "kbd", devkbdport, 1);
	/* likewise the pointer: a receive right, and only one of it. */
	if (devptrport)
		grant_named(p, "ptr", devptrport, 1);
	grant_named(p, "disk", diskport, 0);
	grant_named(p, "sched", schedport, 0);
	grant_named(p, "time", clockport, 0);
	grant_named(p, "dbg", dbgport, 0);

	/* granted: the boot proc reads its rights table on its first
	 * line, so it runs only now.
	 */
	if (p)
		proc_launch(p);
	ipclock_leave();
	return pid;
}

int
kernel_spawn_file(const char *path)
{
	return spawn_init(path, 0, 1);
}

int
kernel_spawn_buffer(const char *code, size_t len)
{
	return spawn_init(code, len, 0);
}

/* run the proc's sys.atexit handlers, last first, on the main state:
 * p->co has finished, but the list lives in p->L's registry.
 *
 * Nothing sets cpu_self()->current here. This runs inside run_proc,
 * which published it for the whole resume, and clearing it mid-resume
 * is what make_ready must not see -- it would enqueue a proc that
 * dispatch still holds. Errors are swallowed as a finalizer's are,
 * since there is no caller left to report them to.
 */
static void
run_atexit(struct kproc *p)
{
	lua_State *L = p->L;
	int n;

	if (lua_rawgetp(L, LUA_REGISTRYINDEX, &atexit_key) != LUA_TTABLE) {
		lua_pop(L, 1);
		return;
	}
	lua_pushnil(L);
	lua_rawsetp(L, LUA_REGISTRYINDEX, &atexit_key);	/* run once */

	n = (int)luaL_len(L, -1);
	for (int i = n; i >= 1; i--) {
		lua_rawgeti(L, -1, i);
		if (lua_pcall(L, 0, 0, 0) != LUA_OK)
			lua_pop(L, 1);	/* swallow the error message */
	}
	lua_pop(L, 1);		/* the handler table */
}

/* resume one READY proc, spending its whole weight. Returns 1 if it ran
 * at all, which is what tells the caller the machine is not idle.
 */
static int
run_proc(struct kproc *p)
{
	int ran = 0;

	/* a proc with weight above 1 is resumed that many times in a row
	 * before dispatch moves on. The whole programmable-scheduler
	 * surface is this loop bound reading an int.
	 */
	for (int w = 0; w < KSTAT_GET(p->weight); w++) {
		/* collect the waits left behind by whoever woke this proc,
		 * before any lua runs. Before the resume rather than
		 * after, because the double-block test reads the same
		 * list: stale entries read as "already blocked".
		 */
		wait_reap(p);

		/* this cpu owns p, so it is the only place the hooks can
		 * be disarmed without racing the target's execution.
		 */
		dbg_settle(p);

		ran = 1;
		KSTAT_ADD(cpu_self()->ndispatch, 1);
		/* where it ran, recorded rather than decided -- nothing
		 * placed it here, this cpu simply took it. Written
		 * outside schedlock because only the cpu running p
		 * writes it, and a reader racing it gets the previous
		 * cpu, which was equally true a moment ago.
		 */
		KSTAT_SET(p->home, cpu_self()->idx);
		KSTAT_ADD(p->nresume, 1);

		int nres = 0;

		unsigned long long t0 = platform_ticks();

		p->resumed = t0;

		/* after p->resumed, so the marker's own cpu delta is
		 * measured against this slice rather than the last one.
		 */
		if (p->trace)
			trace_mark(p, "<scheduled>");

		int rc = lua_resume(p->co, 0, p->nargs, &nres);

		p->nargs = 0;	/* first resume only; see struct kproc */

		atomic_fetch_add_explicit(&p->cputime,
		    platform_ticks() - t0, memory_order_relaxed);
		p->resumed = 0;

		/* drain the 16-byte rx fifo, on a deadline rather than
		 * after every resume. A proc can run a full hook window
		 * before yielding and a lap can carry LAPSPILL dispatches,
		 * so the serial pump is no tight bound on how long the fifo
		 * goes undrained -- hence a drain here as well.
		 * The drain itself is a port i/o trap, and doing it per
		 * resume cost most of a cross-proc round trip. A deadline
		 * well inside the fifo's fill time keeps the guarantee for
		 * two clock reads and a compare.
		 */
		unsigned long long now = platform_ticks();

		unsigned long long last = atomic_load_explicit(
		    &last_uart_drain, memory_order_relaxed);

		if (now - last >= uart_drain_cycles &&
		    atomic_compare_exchange_strong_explicit(&last_uart_drain,
		    &last, now, memory_order_relaxed, memory_order_relaxed))
			uart_poll();
		/* sys.exit, taken at the yield after it: a proc parking
		 * counts, so threads still waiting on ports do not keep a
		 * proc that has said it is done.
		 */
		if (p->exiting) {
			run_atexit(p);
			proc_kill(p, 0);
			break;
		}
		if (rc == LUA_YIELD) {
			lua_pop(p->co, nres);
			/* before the READY test: a stop leaves the queue
			 * by the rule everything else does.
			 */
			if (dbg_commit(p))
				break;	/* held by a debugger */

			/* under the lock that writes it: make_ready sets
			 * READY from whichever cpu woke this proc, and
			 * dispatch reads it again there to decide the
			 * requeue. Reading it here unlocked raced both.
			 */
			lock(&schedlock);
			int ready = KSTAT_GET(p->status) == READY;
			unlock(&schedlock);

			if (!ready)
				break;	/* now BLOCKED */
			continue;	/* spend more weight */
		}
		if (rc == LUA_OK) {
			run_atexit(p);
			proc_kill(p, 0);
		}
		else if (rc == LUA_ERRMEM)
			/* no traceback here: lua reports out of memory
			 * through a preallocated message so that it never
			 * allocates to report having no memory, and building
			 * a traceback would break that and fail again. It
			 * still breaks rather than dies -- such a corpse is
			 * the one most worth reading, and sys.stack allocates
			 * nothing in a target.
			 */
			proc_break(p, lua_tostring(p->co, -1));
		else {
			/* a coroutine that errors out of lua_resume does not
			 * unwind its stack, which is what lets the traceback
			 * be walked here, after resume returned. The error
			 * object is on the stack: read it before the
			 * traceback replaces the top.
			 * Built here as well as held in the corpse, because
			 * this is what reaches the log -- the corpse answers
			 * a question someone thought to ask, the log answers
			 * the one nobody was there for.
			 */
			const char *errmsg = lua_tostring(p->co, -1);

			luaL_traceback(p->co, p->co, errmsg, 0);
			proc_break(p, lua_tostring(p->co, -1));
		}
		break;	/* proc died, nothing left to resume */
	}
	return ran;
}

/* two-level poll backoff for com2, which no firmware event backs: a
 * faster period while bytes arrive, a slower one after a run of empty
 * polls, snapping back the instant a byte shows up.
 * These are measured, not requested. The firmware timer has a hard
 * floor at its own interrupt period, so anything below is silently
 * rounded up while anything above is honored accurately -- see
 * docs/uefi-notes.md. The slow period is the first-byte-after-idle
 * latency for interactive 9p over com2, so going slower is a latency
 * trade rather than free.
 */
#define TICK_FAST_100NS  100000		/* 10ms: the OVMF floor, measured */
#define TICK_SLOW_100NS  150000		/* 15ms, honored accurately */
#define TICK_IDLE_THRESHOLD 25		/* consecutive empty polls before backing off */

/* consecutive laps with nothing dispatched before the heap is swept.
 * Well past the gap between two messages of one exchange, so work is
 * never swept through.
 */
#define QUIET_SWEEP_LAPS 100

/* dispatches by every cpu, which is what "quiet" has to mean: only the
 * boot cpu sweeps, and on its own it cannot tell a still machine from
 * one whose work is all happening on the others.
 */
static unsigned long long
total_dispatch(void)
{
	unsigned long long n = 0;

	for (unsigned i = 0; cpu_at(i); i++)
		n += KSTAT_GET(cpu_at(i)->ndispatch);
	return n;
}

/* how long a proc must sit parked before its collector is run where it
 * lies, and the floor under that in quanta. An rpc takes more than one
 * lap and sometimes more than one round trip, so the wait has to clear
 * a whole exchange rather than a scheduling gap -- otherwise a client
 * is collected between two messages of its own conversation.
 */
#define GCIDLE_MS	50
#define GCIDLE_QUANTA	8

/* the watchdog window, and how often the lap pushes it back. Four pets
 * per window, so three consecutive misses are needed for a reset.
 */
#define WATCHDOG_SECS    60
#define WATCHDOG_PET_MS  15000

/* one phase of a lap: take procs by `take` until the bound runs out or
 * the queue is empty, running each one. Returns whether anything ran.
 *
 * Both phases are this loop, differing in how they choose and in what
 * bounds them. The bound is read at the first acquisition rather than
 * in one of its own, and the requeue of the proc just run shares the
 * acquisition that takes the next -- so a phase costs one acquisition
 * per proc rather than two. It is the acquisitions, not the work under
 * them, that cost; see the note over schedlock.
 */
/* let go of the proc in hand, and do what arrived for it while it was
 * held. The claim and the requeue are one step, or a wakeup between
 * them is lost or enqueued twice. A kill or reap left on the proc runs
 * after, claim dropped and nothing held, so neither reaches into a
 * resume still running.
 */
static void
release_claim(struct cpu *me, struct kproc **held)
{
	struct kproc *p = *held;
	char why[sizeof p->killwhy];
	int kill, reap, freeit;

	*held = 0;
	lock(&schedlock);
	me->current = 0;
	p->oncpu = 0;
	kill = p->killreq;
	reap = p->reapreq;
	freeit = p->killfree;
	p->killreq = 0;
	p->reapreq = 0;
	p->killfree = 0;
	if (kill)
		memcpy(why, p->killwhy, sizeof why);
	if (!kill && KSTAT_GET(p->status) == READY && !p->onq)
		rq_add(donq, p);
	unlock(&schedlock);

	/* freeit is the memory lap's, which wants the state gone */
	if (kill && freeit)
		proc_kill(p, why[0] ? why : "killed");
	else if (kill)
		proc_break(p, why[0] ? why : 0);
	if (reap)
		proc_reap(p);
}

static int
dispatch_phase(struct cpu *me, struct kproc *(*take)(struct rqset *), int floor)
{
	struct kproc *prev = 0;
	int budget = -1, i = 0, ran = 0;

	for (;;) {
		struct kproc *p = 0;

		/* a proc this cpu held can have died while it was `prev`,
		 * and the kill or the reap was left here. Taken before the
		 * lock below, since both of those want it themselves.
		 */
		if (prev)
			release_claim(me, &prev);

		lock(&schedlock);
		if (budget < 0) {
			budget = runq->n;
			if (budget < floor)
				budget = floor;
		}
		/* a proc somebody is reading is put aside rather than run:
		 * see proc_freeze. Taken and set aside under the one lock,
		 * so it cannot be resumed between the two.
		 */
		while (i < budget && (p = take(runq)) && p->frozen) {
			rq_add(donq, p);
			i++;
		}
		if (i >= budget)
			p = 0;
		/* published under the lock and for the whole resume, so
		 * that make_ready can see this proc is in hand and leave
		 * the requeue above to do the enqueueing.
		 */
		if (p) {
			if (p->oncpu)
				platform_abort("proc dispatched on two cpus");
			p->oncpu = me->idx + 1;
			/* a proc that runs is not a proc that has parked.
			 * Stamped here rather than where it blocks, so a
			 * proc yielding round a loop keeps pushing it out. */
			p->gc_idle_ms = uptime_ms();
			i++;
		}
		me->current = p;
		unlock(&schedlock);
		if (!p)
			break;		/* bound spent, or another cpu got there first */
		/* outside the lock, and this is the rule the whole
		 * scheme rests on: a resume runs lua, which can send,
		 * which takes the ipc lock and then this one. Holding
		 * this across it would invert that order and deadlock
		 * against any other cpu doing the same.
		 */
		if (run_proc(p))
			ran = 1;

		/* a corpse is nobody's, and is let go here rather than at
		 * the top of the next turn: a reap on another cpu frees
		 * the state of anything it can see is BROKE, and the step
		 * below would follow that pointer.
		 */
		lock(&schedlock);
		int gone = KSTAT_GET(p->status) == DEAD ||
		    KSTAT_GET(p->status) == BROKE || p->killreq;
		unlock(&schedlock);

		if (gone) {
			prev = p;
			release_claim(me, &prev);
			continue;
		}
		/* the collector's safe point, and the only one. Here
		 * rather than inside run_proc because nothing is held
		 * here, and no C local holds anything reachable only from
		 * lua -- run_proc's error paths carry lua strings while
		 * they build a traceback.
		 *
		 * After the resume, not before: a proc that blocks and is
		 * never woken reaches no point before its next resume, and
		 * its garbage would sit for as long as it stayed parked.
		 */
		gc_step(p, p->L, 0);
		prev = p;
	}
	return ran;
}

/* how much a parked proc must have allocated since it was last
 * collected whole for the collect to be worth taking. Below this the
 * cycle costs more than it can return, and the procs that park most
 * often -- a client between two requests -- allocate least.
 */
#define GCIDLE_MIN	(64 * 1024)

/* collect the procs that have parked, which nothing else will: gc_step
 * runs at a dispatch point. Per lap rather than on a quiet machine,
 * because the proc that most needs collecting is often parked while
 * the rest of the machine is busy. A proc is claimed as dispatch claims
 * one: this is a resume of its finalizers. */
static void
gc_idle_sweep(struct cpu *me)
{
	unsigned long long now = uptime_ms();
	unsigned long long wait = GCIDLE_MS;

	/* a platform whose quantum is coarse gets the same guarantee in
	 * its own units: the wait must outlast a slice however long one
	 * is here, or a proc merely descheduled looks parked.
	 */
	if (wait < (unsigned long long)quantum_ms * GCIDLE_QUANTA)
		wait = (unsigned long long)quantum_ms * GCIDLE_QUANTA;

	for (int i = 0, n_ = atomic_load_explicit(&prochigh,
	    memory_order_acquire); i < n_; i++) {
		struct kproc *p;

		/* ipclock for the slot, because proc_new wipes a recycled
		 * one; schedlock for the fields; in that order. BLOCKED
		 * and nothing else: a corpse must not run a finalizer, a
		 * HATCHING proc has no chunk yet, and a runnable one is
		 * about to reset its own clock.
		 */
		ipclock_enter();
		lock(&schedlock);
		p = procv[i];
		if (!p || KSTAT_GET(p->status) != BLOCKED || p->oncpu || p->frozen ||
		    p->onq || p->gc_idle_owed < GCIDLE_MIN ||
		    now - p->gc_idle_ms < wait) {
			unlock(&schedlock);
			ipclock_leave();
			continue;
		}
		p->oncpu = me->idx + 1;
		me->current = p;
		unlock(&schedlock);
		ipclock_leave();

		gc_idle_collect(p);

		lock(&schedlock);
		me->current = 0;
		p->oncpu = 0;
		if (KSTAT_GET(p->status) == READY && !p->onq)
			rq_add(donq, p);
		unlock(&schedlock);
	}
}

/* one lap of dispatch on one cpu: both phases, then the drain and the
 * swap. Every cpu that schedules runs this and nothing else. What the
 * boot processor does around it -- the device pumps, the timers, the
 * firmware tick -- is machine-wide work an AP must not touch, rather
 * than part of scheduling. Returns whether anything ran, which is what
 * the caller's idle decision rests on.
 */
static int
dispatch_lap(struct cpu *me)
{
	int ran = 0;

	/* phase one is bounded by how many were waiting when it started,
	 * so it cannot spin on procs it keeps waking.
	 */
	if (dispatch_phase(me, rq_take_high, 0))
		ran = 1;

	/* the bound is what makes the lap terminate at all: a proc woken
	 * mid-lap joins the current runq, so two procs feeding each
	 * other hand this phase a fresh proc every time it takes one. An
	 * unbounded drain never reaches the top of the loop again, where
	 * the timers and the device pumps live, and one busy pair would
	 * stop every timer on the machine. LAPSPILL is the floor that
	 * keeps the bound from being expensive.
	 */
	if (dispatch_phase(me, rq_take_any, LAPSPILL))
		ran = 1;

	/* where this cpu holds nothing; a null test per proc otherwise */
	dbg_sweep();

	/* the same place and for the same reason: a corpse the cap could
	 * not reap at the death that made it is reaped here instead. One
	 * atomic load when there is nothing to do.
	 */
	proc_reap_excess();

	/* the lap ends when runq is empty, and whichever cpu empties it
	 * says so. With one queue that is the only workable boundary: a
	 * cpu cannot swap on its own schedule without handing the others
	 * procs that already had a turn.
	 *
	 * Counting the cpus inside a lap and letting the last one out
	 * swap livelocks instead -- cpus finishing early re-enter at
	 * once, so they are never all out together, and every cpu churns
	 * empty laps over a runq whose procs all sit in donq.
	 */
	lock(&schedlock);
	if (runq->n == 0 && donq->n > 0) {
		struct rqset *t = runq;

		runq = donq;
		donq = t;
	}
	unlock(&schedlock);

	return ran;
}

/* what an application processor runs, and the whole of it. The boot
 * processor's loop is the same two phases wrapped in machine-wide work
 * -- device pumps, timers, the firmware tick -- and none of that is an
 * AP's business. Under efi it could not be: TPL is one cooperative lock
 * and an AP calling firmware is undefined, so this inherits that
 * division rather than inventing one.
 *
 * The idle is a real sleep, ended by the reschedule ipi make_ready
 * sends when it puts work on the queue.
 */
void
kernel_run_ap(void)
{
	struct cpu *me = cpu_self();

	lock(&schedlock);
	KSTAT_SET(me->dispatching, 1);
	unlock(&schedlock);

	while (atomic_load_explicit(&nlive, memory_order_relaxed) > 0) {
		KSTAT_ADD(me->nlaps, 1);
		if (ipcheld_any())	/* see kernel_run; the same check */
			platform_abort("ipclock held across a lap");
		if (dispatch_lap(me)) {
			KSTAT_ADD(me->ndispatch, 1);
			continue;
		}

		/* nothing to run. Publish that under the lock, which is
		 * where make_ready reads it to decide whether to send the
		 * ipi, so this cannot sleep just after someone decided it
		 * did not need waking. The lock settles who decides; it
		 * does not close the window. An ipi sent the instant after
		 * the lock drops would be taken as an ordinary interrupt
		 * and lost, and the sleep would never end with work
		 * already queued. So interrupts go off before the queue is
		 * looked at, and stay off into platform_cpu_idle.
		 */
		platform_intr_off();
		lock(&schedlock);
		if (runq->n + donq->n > 0) {
			unlock(&schedlock);
			platform_intr_on();
			continue;
		}
		KSTAT_SET(me->idle, 1);
		unlock(&schedlock);

		KSTAT_ADD(me->nidle, 1);
		platform_cpu_idle();	/* returns with interrupts on */

		lock(&schedlock);
		KSTAT_SET(me->idle, 0);
		unlock(&schedlock);
	}

	lock(&schedlock);
	KSTAT_SET(me->dispatching, 0);
	unlock(&schedlock);
}

void
kernel_run(void)
{
	EFI_EVENT tick = 0;
	EFI_EVENT ethwait = platform_dev_wait();
	EFI_EVENT waits[3];
	UINTN index;
	int idle_polls = 0;
	int tick_slow = 0;
	int quiet_laps = 0, swept = 0;
	unsigned long long last_dispatch = 0;
	unsigned long long last_watchdog_ms = 0;

	/* periodic timer: idle becomes a real firmware sleep (hlt)
	 * instead of a hot stall-poll. the old "timer hangs the serial
	 * path" mystery was firmware console contention on com2, fixed
	 * by uart_takeover().
	 */
	if (BS->CreateEvent(EVT_TIMER, TPL_CALLBACK, 0, 0, &tick) !=
	    EFI_SUCCESS ||
	    BS->SetTimer(tick, TimerPeriodic, TICK_FAST_100NS) != EFI_SUCCESS)
		tick = 0;

	lock(&schedlock);
	KSTAT_SET(cpu_self()->dispatching, 1);
	unlock(&schedlock);

	while (atomic_load_explicit(&nlive, memory_order_relaxed) > 0) {
		struct cpu *me = cpu_self();
		int ran;

		KSTAT_ADD(cpu_self()->nlaps, 1);

		/* nothing may hold the ipc lock across the top of a lap.
		 * This catches the release a lua error jumped past, which
		 * is the failure mode the lua-facing acquisitions have and
		 * which no amount of reading finds reliably.
		 * This cpu, not any cpu: another holding it here is
		 * ordinary. Any bucket, never every one: a leak is a
		 * single missed release, so demanding all eight asks
		 * whether this cpu is inside a wide region, which answers
		 * no for exactly the case this exists to catch.
		 */
		if (ipcheld_any())
			platform_abort("ipclock held across a lap");

		/* drain the periodic timer's signal. nothing is paced
		 * against it any more, but a tick that fires during a busy
		 * lap stays signaled otherwise, and the WaitForEvent below
		 * would then return at once instead of sleeping.
		 */
		if (tick)
			BS->CheckEvent(tick);

		/* push the watchdog back. Throttled: a lap is
		 * milliseconds and this is a firmware call.
		 */
		{
			unsigned long long now = uptime_ms();

			if (now - last_watchdog_ms >= WATCHDOG_PET_MS) {
				last_watchdog_ms = now;
				platform_watchdog(WATCHDOG_SECS);
			}
		}

		expire_timers();
		pump_eth();
		pump_net();
		pump_hci();
		pump_gps();
		pump_keyboard();
		pump_devkbd();
		pump_devptr();
		if (pump_serial()) {
			idle_polls = 0;
			if (tick_slow && tick) {
				BS->SetTimer(tick, TimerPeriodic,
				    TICK_FAST_100NS);
				tick_slow = 0;
			}
		} else if (!tick_slow && tick) {
			if (++idle_polls >= TICK_IDLE_THRESHOLD) {
				BS->SetTimer(tick, TimerPeriodic,
				    TICK_SLOW_100NS);
				tick_slow = 1;
			}
		}
		/* two phases, and the split is the whole design. Phase one
		 * takes the highest priority first, so an interactive proc
		 * answers before a hog gets another turn. Phase two takes
		 * whatever is left, priority never consulted, including
		 * anything woken during phase one. Phase two is the
		 * starvation guarantee, deliberately independent of the
		 * priority function: a policy that is buggy or hostile can
		 * cost latency, but cannot wedge the machine. Both phases
		 * are bounded, and "had its turn" is membership in donq.
		 */
		ran = dispatch_lap(me);

		/* the parked procs, then a quiet machine's chunks. Both
		 * are here rather than anywhere else in the lap because
		 * this is a safe point: no lock is held and no C local
		 * holds anything reachable only from lua.
		 */
		gc_idle_sweep(me);

		/* memory ran short since the last lap. The cached chunks
		 * are given back first, because that costs nothing and
		 * often answers it; a shortage that survives that takes
		 * the largest proc marked expendable.
		 */
		if (kmem_low()) {
			kmem_low_clear();
			proc_heaps_release();

			/* asked after the release, not before: a shortage
			 * the caches answered must not cost a proc. And
			 * asked rather than inferred from another failure,
			 * because a proc that took the memory and parked
			 * makes no further ones.
			 */
			if (kmem_short()) {
				struct kproc *v = kmem_victim();

				if (v)
					proc_kill(v, "killed: out of memory");
			}
		}

		/* a quiet machine gives its heap back: the large-block
		 * cache is held against a next request that is not coming.
		 * Once per spell, since the sweep walks the free lists and
		 * would find nothing twice.
		 */
		unsigned long long disp = total_dispatch();

		if (ran || disp != last_dispatch) {
			quiet_laps = 0;
			swept = 0;
		} else if (!swept && ++quiet_laps >= QUIET_SWEEP_LAPS) {
			swept = 1;
			proc_heaps_release();
		}
		last_dispatch = disp;

		if (!ran) {
			/* everyone blocked: sleep until a key, a frame, or
			 * the tick. Without the wire here a frame waits for
			 * the next tick, because the eth pump runs only at
			 * the top of a lap. ethwait may be 0, for no card or
			 * a driver publishing no event, and then the tick is
			 * the bound again.
			 */
			KSTAT_ADD(cpu_self()->nidle, 1);
			if (tick) {
				UINTN n = 0;

				waits[n++] = ST->ConIn->WaitForKey;
				waits[n++] = tick;
				if (ethwait)
					waits[n++] = ethwait;
				BS->WaitForEvent(n, waits, &index);
			} else
				BS->Stall(500);
		}
	}
}

int
kernel_current_has_disk(void)
{
	return proc_has_port(cpu_self()->current, diskport);
}

/* the transcript, for sys.dmesg. Copies at most `max` bytes from `from`
 * onward, and reports where to read next and how much was overwritten
 * before the reader got to it. A `from` of -1 starts at the oldest.
 */
size_t
kernel_dmesg(long long from, char *out, size_t max, unsigned long long *next,
    unsigned long long *dropped)
{
	unsigned long long start;
	size_t n;

	*dropped = 0;
	if (max > LOGCHUNK)
		max = LOGCHUNK;
	lock(&loglock);

	unsigned long long oldest = logoldest();

	if (from < 0 || (unsigned long long)from < oldest) {
		if (from >= 0)
			*dropped = oldest - (unsigned long long)from;
		start = oldest;
	} else if ((unsigned long long)from > logseq) {
		start = logseq;
	} else {
		start = (unsigned long long)from;
	}

	n = (size_t)(logseq - start);
	if (n > max)
		n = max;
	if (n) {
		size_t o = (size_t)(start % logsize);
		size_t first = logsize - o < n ? logsize - o : n;

		memcpy(out, logring + o, first);
		if (first < n)
			memcpy(out + first, logring, n - first);
	}
	unlock(&loglock);
	*next = start + n;
	return n;
}

/* what sys.loginfo reports: bytes ever written, the ring's size, the
 * oldest byte still in it, and how many went unread.
 */
void
kernel_loginfo(unsigned long long *seq, size_t *size,
    unsigned long long *oldest, unsigned long long *lost)
{
	lock(&loglock);
	*seq = logseq;
	*size = logsize;
	*oldest = logoldest();
	*lost = loglost;
	unlock(&loglock);
}
