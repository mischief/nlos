#ifndef COREG_H
#define COREG_H

/* every lua_State a proc owns, on a list the kernel can walk.
 *
 * injected into lua through LUA_USER_H (lua/lua.h), which is what that
 * hook is for -- lua's own ltests.h redefines LUA_EXTRASPACE and the
 * luai_userstate* macros exactly this way. nothing in lua/ is patched;
 * it is a submodule of upstream.
 *
 * the kernel has to reach all of a proc's coroutines to arm the
 * preemption hook on them: lua_newthread copies hook, mask and count at
 * creation and never looks again, so a hook set on one coroutine
 * reaches no other, and a proc whose thread runs a scheduler of its own
 * escapes the quantum entirely (see docs/scheduling.md). inferring the
 * set by walking the proc's globals (src/debug.c) misses any coroutine
 * held only from a C closure's upvalue or a live local.
 *
 * lua calls the two hooks at exactly the right moments:
 * luai_userstatethread after a new state's extra space has been copied
 * from the main thread, and luai_userstatefree before its memory goes
 * back.
 *
 * the links live in the per-state extra space rather than a table in
 * the proc's registry, for two reasons. nothing here allocates, which
 * matters because the walk runs inside a debug hook and may run while
 * the proc is at its memory limit -- the same constraint src/debug.c is
 * built around. and a registry table is reachable through
 * debug.getregistry, which non-boot procs keep, so a proc could clear
 * the mechanism meant to contain it.
 */

#include <sys/queue.h>

struct kproc;
struct lua_State;

struct kextra {
	struct kproc *p;		/* offset 0: see self() in kernel.c */
	TAILQ_ENTRY(kextra) link;
	/* this state's last yield came from preempt_hook rather than from
	 * the code running in it. lua_yield unwinds to the RESUMER of the
	 * state it fires in, so for a coroutine that is whoever called
	 * resume -- ordinary code that never asked to be interrupted and
	 * reads a yield of no values as "finished". kernel_cowrap resumes
	 * again instead of believing it; see preempt_hook.
	 */
	int preempted;
};

#undef LUA_EXTRASPACE
#define LUA_EXTRASPACE		(sizeof(struct kextra))

void	kernel_costart(struct lua_State *from, struct lua_State *nw);
void	kernel_cofree(struct lua_State *from, struct lua_State *dead);

#define luai_userstatethread(L, L1)	kernel_costart(L, L1)
#define luai_userstatefree(L, L1)	kernel_cofree(L, L1)

#endif
