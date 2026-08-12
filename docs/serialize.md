# The serializer

Messages travel between procs as bytes. The serializer turns a lua value
into those bytes and back, and it is the only place a capability crosses
from one proc into another.

## Wire format

One tag byte, then the tag's payload:

| tag | payload |
| --- | --- |
| `N` `T` `F` | nothing: nil, true, false |
| `I` | int64 |
| `D` | double |
| `S` | u32 length, then bytes |
| `B` | u32 pair count, then key/value pairs |
| `R` | u16 port index, u8 recv flag |
| `M` | u8 buffer index |

The port index is 16 bits, which is what bounds `MAXPORTS`. A static
assert in kernel.c holds the two together.

Functions, coroutines, and userdata other than `los.buf` do not travel.
There is no cycle detection; `MAXDEPTH` bounds recursion instead.

## What a table can mean

Three table shapes are not data:

- `{__right = h}` **copies** a right. The sender's handle stays live and
  still counts against `MAXRIGHTS`, so a caller minting one per request
  must close its own. Rights are copied, not moved — this is the single
  most common source of handle leaks in this tree.
- `{__buf = b}` **moves** bytes. The sender is left holding an empty
  handle that raises on use, so a mistake shows at the line that made it
  rather than as two procs writing over one another. Only storage its
  holder alone owns may travel; `luabuf_borrow` decides, and anything
  else is refused rather than quietly copied, because a silent copy would
  hide the cost the transfer exists to remove.
- A bare `los.buf` is copied and arrives as a string, so a sender need
  not cut one first.

## Two failures that are not symmetrical

Serializing can fail after it has taken port refs; deserializing can fail
after it has minted rights into the receiver. Both must be undone, and
the second matters more: a message is accepted whole or not at all,
and a half-installed right was never pushed to lua, so the receiver
cannot name it to close it. It is lost for the life of the proc. A sender
chooses both the count and the point of failure, so without `minted_undo`
this is how a client drains a server's rights table from outside.

A receive right in flight counts toward the port's `nrecv` immediately,
before it exists in the receiver. Without that, a sender that closes its
own copy after queueing takes `nrecv` to zero, which marks the port dead
and flushes the queue while a good receive right is still on its way.

## Sizing

`sizehint` guesses a message's size so the common case does not realloc
mid-walk. It is a hint in the strict sense: `wput` grows the buffer
whenever the guess is short, so being wrong costs a realloc and never
correctness. That independence is the point — it skips serialize's type
dispatch entirely, so it cannot drift out of sync with it, and looks only
for what actually makes a message big, which is strings.

It walks one level. The shape it exists for is a table wrapping one
payload, which is every mnt reply.

`MAXMSG` bounds the message, not the growth policy. Doubling may
overshoot and get clamped; only a message that genuinely does not fit is
refused.

## Measuring

`sys.stats().ipc` reports message and byte counts per port. To see
whether sizing is working, compare reallocs against messages sent under
a 9P read load, where payloads are large and the reply shape is fixed.
