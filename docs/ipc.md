# Ports and rights

A port is a kernel message queue. A right is a per-proc handle onto one.
Lua never sees a pointer: handle 0 is always the proc's own receive
port, and every other handle is a small integer in a per-proc table.

`docs/locking.md` covers the lock over all of this, which is where the
difficulty is. This file is the shape of the objects underneath it.

## Ports are named by index

The wire carries a port's index, not its pointer. A message stays the
same size whatever the machine's word size, and a port keeps its
identity if its body moves. Bodies are heap-allocated, so `.bss` holds
one pointer per slot rather than a whole port for every port that could
ever exist.

Slots are reused. An index alone therefore cannot say whether the port
behind it is the one you meant, so anything that names a port across
time keeps the pair (index, generation) — see `kproc.selfidx`. The
generation is 64-bit and increments once per port, so it does not wrap
in any run this machine could have.

The wire field is 16 bits, which is what bounds `MAXPORTS`. A static
assert in the serializer holds the two together.

## Rights are copied, not moved

`{__right = h}` in a message copies the right. The sender's handle stays
live and still counts against `MAXRIGHTS`, so a caller minting one per
request must close its own. This is the most common source of handle
leaks in this tree.

`sys.sendright(h)` derives a send-only right from one you hold. Mach's
shape: a receive right is the authority to hand out send rights. It
matters because `{__right = h}` copies the recv flag, so handing out a
port you created would also hand out the ability to receive on it — and
on a port many clients share, any of them could then take another's
requests, or take their own and never answer.

`api_send` ignores the flag, so a send right is all a client ever needs.

## Eof is "am I the only holder"

Plan 9's pipes count opens of each end, which they can because a Chan is
explicitly a read or a write end. Rights make no such distinction: any
right can send, and the recv flag only feeds port-death bookkeeping. So
"no senders left" is not a question this model can answer.

"Am I the only holder" is, and for a pipe it means the same thing: if
nobody else holds a right, nobody can ever write again, so whatever is
queued is all there will be. `sys.hungup(h)` asks it.

It counts every right the asking proc holds rather than testing the
port's total against one, because a caller may hold several to one port
— a reply port is a receive right to wait on plus a send right to
publish. A right it holds itself cannot answer it.

In-flight rights inside undelivered messages still count, so a right on
its way to a new writer correctly keeps the pipe open. **A pipe's
creator must drop its own right after handing the ends out**, or it
stays a holder forever and eof never arrives.

A receive right in flight counts toward the port's `nrecv` immediately,
before it exists in the receiver. Without that, a sender that closes its
own copy after queueing takes `nrecv` to zero, which marks the port dead
and flushes the queue while a good receive right is still on its way.

`sys.hangups()` is the machine-wide edge: a counter that moves whenever
any port anywhere loses a reference. A ready-port hint can never name a
hangup, because the thread that must notice its peer is gone has nothing
queued. It is a "go look" signal and the looking is `sys.hungup`.

## The queue ceiling

`MAXQUEUE` bounds what one port holds. Without it a fast writer into a
slow reader grows the kernel heap without limit, and that memory is
charged to no proc's `mem_limit`, so it does not appear in the
containment accounting at all.

Over the limit the send fails rather than blocking. The kernel must not
pick a policy here: it cannot tell a pipe write from a server reply, and
blocking would let one slow reader wedge a server for every other
client. So it reports, and lua decides — the same split the receive side
makes, with the loop living in lua.

A refused send reports how many bytes it refused, so that policy can be
"wait for room" without lua working out how much. Only the serializer
can produce that figure.

**Pass the real size to `sys.sendblock`.** A message that is a large
fraction of `MAXQUEUE` is refused while the queue still reports room, so
a caller asking for room for zero bytes wakes, fails to send, and parks
again — burning its whole slice instead of sleeping. Small messages
never show it.

Transferred buffer bytes count against the queue too. They are not in
the message, so without that a sender could park megabytes on a queue
nobody drains while `MAXQUEUE` read as empty.

## Input ports are not shared

The console keyboard, a second keyboard, and the pointer each get their
own port. Two terminals sharing one input port would race for every
keystroke, and which one won would depend on who asked first. Two
readers of one pointer would each see half of a drag.

The pointer's records are plan 9's mouse format: `m` and four
fixed-width fields. Fixed width so a reader asks for one record's worth
and gets exactly one event, needing no framing rule of its own.

## Measuring

`sys.ports()` reports per-port counters the kernel is the only place
able to keep: messages sent, sends refused for a full queue, sends
refused for a dead port, and the queue's high-water mark.

Full and dead are separate because they are different faults — a full
queue is a reader that fell behind, a dead one is a receive right closed
while someone was still sending. The high-water mark matters because a
queue is almost never sampled at its worst moment: one that touched
`MAXQUEUE` and drained reads as idle, and that is exactly the port worth
knowing about.

Ports also record who created them and where. A port that is never
closed is a slow fault — the machine runs out weeks later, and a total
says nothing about which of fifty call sites is at fault — so
`sys.newport` takes a tag naming what the port is for.
