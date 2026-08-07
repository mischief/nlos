#ifndef BUF_H
#define BUF_H

#include <stddef.h>

#include "lua.h"

/* the bytes of a string or a los.buf at idx, or null for anything else.
 * What lets a function that takes a payload take either without a
 * second path through it.
 */
const char *luabuf_bytes(lua_State *L, int idx, size_t *len);

/* the same, raising for anything else: for a C function whose argument
 * is a payload. */
const char *luabuf_check(lua_State *L, int idx, size_t *len);

/* the bytes of a writable buffer, or null for anything a caller may not
 * write: for a C function that produces its result into one. */
unsigned char *luabuf_writable(lua_State *L, int idx, size_t *len);

/* pooled bytes, charged to the proc running L against the same cap as
 * its lua memory. charge returns 0 when the cap would be exceeded.
 *
 * Buffer storage comes from the chunk source rather than the proc's lua
 * heap (see buf.c), so nothing else counts it.
 */
int	kbuf_charge(lua_State *L, size_t n);
void	kbuf_uncharge(lua_State *L, size_t n);

/* every proc's pooled bytes, for sys.stats() */
size_t	kbuf_pooled(void);

#endif
