#ifndef PORT_H
#define PORT_H

/* ports, rights, and message delivery. see docs/ipc.md, and
 * docs/locking.md for the lock over all of it.
 */

#include <stddef.h>

#include "lua.h"
#include "kproc.h"

/* the port table. The wire carries an index into this, so a slot and
 * the port in it are told apart by kport.gen.
 */
extern struct kport *portv[MAXPORTS];
extern atomic_int porthigh;	/* one past the highest slot ever used */

/* the buffers travelling on one message: free what nobody received,
 * and what they cost the queue they sit on.
 */
void	msgbufs_free(struct msgbufs *b);
size_t	msgbufs_bytes(const struct msgbufs *b);

struct kport *port_new(void);
void	port_flush(struct kport *port);

/* has this proc room for another port, against its inherited cap? */
int	port_budget_left(struct kproc *p);

/* the port behind this proc's handle 0, or null if it has gone. */
struct kport *proc_selfport(struct kproc *p);
int	proc_has_port(struct kproc *p, struct kport *port);

/* queue a message. port_push copies; port_push_owned takes `data` only
 * when it returns 0, and on any refusal the caller still owns the
 * buffer and the in-flight refs. Both need the bucket covering `port`.
 */
int	port_push_owned(struct kport *port, unsigned char *data, size_t len,
	    const unsigned short *refs, const unsigned char *refrecv,
	    int nrefs, const struct msgbufs *bufs);

/* take the head message off `port`, or null. Caller holds its bucket. */
struct kmsg *port_pop(struct kport *port);
void	msg_dispose(struct kmsg *m);
void	msg_free(struct kmsg *m);

/* release rights serialized into a message that was never delivered.
 * The _locked form takes the lock itself, for a caller that cannot hold
 * one across the raises between its calls.
 */
void	release_inflight(const unsigned short *refs,
	    const unsigned char *refrecv, int n);
void	release_inflight_locked(const unsigned short *refs,
	    const unsigned char *refrecv, int nrefs);

/* grant a named capability, which lua looks up through sys.granted(). */
void	grant_named(struct kproc *p, const char *name, struct kport *port,
	    int recv);

/* attach p to port's wait list, or drop the waits it holds. wait_reap
 * runs on the proc's own cpu before it is resumed; wait_clear is for a
 * proc that is dying or restarting its wait set.
 */
int	wait_add(struct kproc *p, struct kport *port, int send);
void	wait_clear(struct kproc *p);
void	wait_reap(struct kproc *p);

/* wake whoever is parked on this port. Caller holds its bucket. */
void	wake_receivers(struct kport *port);
void	wake_senders(struct kport *port);

/* a counter that moves whenever any port loses a reference, which is
 * the only way sys.hungup's answer can change.
 */
unsigned long long port_hangups(void);

/* the high-water mark of any proc's handle table, and how the wake
 * claim went: won, or lost to another port reaching the same proc.
 */
int	port_rights_high(void);
unsigned long long port_claims(int won);

/* what sys.stats() reports about the buckets: summed over all of them. */
void	ipclock_stats(unsigned long long *nlock, unsigned long long *ncontend,
	    unsigned long long *spin, unsigned long long *held);

#endif
