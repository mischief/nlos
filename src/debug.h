#ifndef DEBUG_H
#define DEBUG_H

#include "lua.h"

/* Push an array of { label, status, frames } onto `to`, describing every
 * coroutine of the proc whose main state is `target_main` and whose own
 * coroutine is `target_co`.
 *
 * Reads the target without running any of its code, allocating in its
 * heap, or leaving its stack changed. See debug.c for what that costs
 * and what it misses.
 */
void	debug_push_stacks(lua_State *to, lua_State *target_main,
	    lua_State *target_co);

#endif
