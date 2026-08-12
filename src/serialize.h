#ifndef SERIALIZE_H
#define SERIALIZE_H

/* lua values to bytes and back. see docs/serialize.md. */

#include <stddef.h>

#include "lua.h"
#include "kproc.h"

struct wbuf {
	unsigned char *p;
	size_t len, cap;
	/* ports named by rights in this message. each holds a ref taken
	 * here, released on send failure or by msg_free.
	 */
	unsigned short refs[MAXMSGRIGHTS];
	unsigned char refrecv[MAXMSGRIGHTS];
	int nrefs;
	/* buffers this message takes over. bufown is emptied only once
	 * the message is queued, so a failed send keeps its bytes.
	 */
	struct msgbufs bufs;
	void *bufown[MAXMSGBUFS];
};

/* handles deserialize has minted into the receiver. a walk that fails
 * partway gives them back: they never reached lua, so the receiver
 * cannot close them, and a sender could drain a server's table.
 */
struct minted {
	int h[MAXMSGRIGHTS];
	int n;
};

/* the byte writer. both return -1 if the message would pass MAXMSG. */
int	wput(struct wbuf *w, const void *src, size_t n);
int	wbyte(struct wbuf *w, unsigned char c);

/* guess the serialized size at idx, and pre-size a wbuf to it. a hint
 * only: wput grows whenever it comes up short, so being wrong costs a
 * realloc and never correctness.
 */
size_t	sizehint(lua_State *L, int idx);
void	wreserve(struct wbuf *w, size_t n);

/* write the value at idx into w, taking a ref on every port it names.
 * returns -1 if the value cannot travel or the message is too big; the
 * caller releases w->refs on failure.
 */
int	serialize(lua_State *L, int idx, struct wbuf *w, struct kproc *sender,
	    int depth);

/* read one value, pushing it on L. -1 is a malformed message, -2 a
 * local limit (a full rights table, or receiver->bufdenied). mt
 * collects minted rights; pass it to minted_undo on any failure.
 */
int	deserialize(lua_State *L, const unsigned char *p, size_t len,
	    size_t *off, struct msgbufs *bufs, struct kproc *receiver,
	    int depth, struct minted *mt);
void	minted_undo(struct kproc *p, struct minted *mt);

#endif
