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

/* ---- transfer ----
 *
 * A buffer travels by changing owner. The steps are separate because a
 * send can fail after the message is built: the sender keeps its bytes
 * until the message is queued.
 *
 * borrow gives the bytes and a handle for detach. It is null unless the
 * buffer is storage its holder alone owns: not a string, a view, a
 * read-only buffer, one with views onto it, or one given away.
 *
 * detach empties that handle and uncharges the proc.
 *
 * give pushes a buffer owning p, charged to the proc running L. It
 * returns 0, pushing nothing, when that would exceed the proc's cap.
 */
const char *luabuf_borrow(lua_State *L, int idx, size_t *len, void **handle);
void	luabuf_detach(lua_State *L, void *handle);
int	luabuf_give(lua_State *L, void *p, size_t len);

/* push a buffer of n bytes and return its storage, for a C function
 * that fills one -- a device read. Null, pushing nothing, when the proc
 * cannot afford it. The bytes are not initialised.
 *
 * Making the lua object can collect, and a finalizer can run any lua,
 * including code that reaches the same driver. So this is for a caller
 * that fills the storage AFTER it is handed back. A caller copying out
 * of memory the device still owns must not hold that pointer across
 * this: allocate with luabuf_alloc, copy, and hand the result to
 * luabuf_give once nothing borrowed is left.
 */
unsigned char *luabuf_push(lua_State *L, size_t n);

/* pooled storage with no lua object attached, and its release for a
 * caller that never reaches luabuf_give. Neither touches lua. */
void	*luabuf_alloc(size_t n);
void	 luabuf_free(void *p, size_t n);

/* buffers allocated since boot, for sys.stats() */
unsigned long long luabuf_allocs(void);

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
