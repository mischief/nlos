# namespace / capability design (parked)

brood from 2026-07-15, recorded for another day. status: DESIGN ONLY,
nothing built. answers "how would per-proc namespaces work, and how do
we use the port/right system so each proc has minimal surface" —
building on plan9 namespaces but going further than plan9 ever did.

## plan9 baseline, and where it under-explored this

plan9 namespace = per-process table of path-prefix -> mount point,
built by bind/mount, inherited copy-on-fork from the parent, free to
diverge after (rfork(RFNAMEG)). union directories let multiple servers
answer the same path, in order.

but plan9's security model underneath is thin: any process holding a
fd to a service can bind it anywhere in its own namespace, and the
namespace itself is just data — nothing gates what a process may bind,
only what it already happens to have open. a process gets a full copy
of the parent's namespace by default (including /proc, /net, /dev —
large ambient surface) and prunes downward. least privilege is
opt-in (an rfork flag), not the default shape. plan9 never married
namespace construction to capability-scoped construction.

## what our port/right system already gives that plan9 didn't have

a right is unforgeable, unnamed until delivered, and travels only by
explicit message ({__right=h} in a sent table). that is strictly
stronger than a plan9 fd. so a namespace layer on top of it can be
capability-driven from birth, not pruned after the fact: a proc's
namespace can only ever contain mounts built from rights it was
actually given — never a copy of ambient anything.

## Chan/Dev vs 9p wire: the boundary we're actually locating

worth being precise about where plan9's *own* kernel draws this line,
because it settles a question that comes up naturally once ports
exist: should procs talk to each other in 9p?

no. plan9's in-kernel `Chan` (portdat.h) is a plain C struct — qid,
offset, mount-union links, a pointer — with no wire bytes anywhere in
it. every `Dev` (devcons, devsrv, ...) is called through direct
function pointers (`walk`, `read`, `write`) operating on that struct;
zero serialization between in-kernel participants. the 9p wire codec
(`convM2S`/`convS2M`) only appears in `devmnt.c` — the one driver
whose entire job is being the seam to something that is *not*
in-kernel: a mounted remote 9p server, a user-space file server via
`srv`/`exportfs`. the instant a `Chan` needs to leave the kernel's
address space it gets flattened to bytes on the wire; the moment
something comes back in, it's rehydrated into a `Chan` and every other
device forgets the wire existed.

that is exactly our split, already built, before this doc was written:

- `struct kport`/`struct right` (kernel.c) ≈ `Chan` — live, in-process,
  function-call/memcpy cheap, referenced by index, never serialized
  between procs that share our kernel.
- `lib/ninep.lua`'s wire codec ≈ `devmnt.c` — the one place doing
  `convM2S`/`convS2M`-equivalent work, and only because the far end
  (an external plan9port client today, eventually a real host mount
  over microvm virtio-9p) genuinely does not share our address space.

so the namespace mount table's 9p-*shaped* walking (prefix -> mount,
longest-match, remaining path as a walk) borrows plan9's naming idea
without borrowing 9p's wire format — same as `Chan` does internally.
proc-to-proc IPC should stay on the native port serializer forever;
routing it through 9p framing between procs that already share a
kernel would be re-inventing `devmnt.c` for a boundary that doesn't
exist. arguably we can be *more* disciplined here than plan9's own
in-kernel devices (`devcap` among them), which sometimes reach for
string-y encodings out of convenience even when nothing is crossing
the wire — our serializer stays a native structured format (tables,
ints, floats, rights) precisely because nothing forces stringification
until an actual boundary is crossed.

## the shape

- **namespace = per-proc lua table**: `{prefix -> mountpoint}`, where
  a mountpoint is `{right=h, ...}` — essentially a partially-walked
  9p fid. each proc that mounts "the same" service gets its own walk
  state, matching 9p fid semantics and keeping isolation clean.
- **spawn-time construction, not inherit-then-prune.**
  `sys.spawn(code, {ns = {["/"] = fs_right, ["/net"] = net_right}})`
  — the parent hands the child exactly the mount table, built only
  from rights the parent already holds. no copy-then-restrict; the
  child never sees more than what was assembled. **the namespace
  constructor IS the capability grant**: you cannot mount what you
  were not sent.
- **no ambient bind.** plan9's `bind("#c", "/dev")` reaches into a
  global device namespace by name string. we have no global device
  namespace — every service is a proc behind a right, so there is no
  "bind anything you can name," because naming does not imply access
  here. a proc can only mount rights already sitting in its own rights
  table. this closes plan9's biggest gap: names are cheap in plan9
  (any string), rights are not (must be delivered). namespace built on
  rights inherits that discipline for free.
- **union = ordered list of rights per prefix**, same walk-fallthrough
  plan9 does, but each element independently revocable — dropping a
  right silently removes it from the union (no dangling fd; the
  kernel's existing refcount/monitor machinery already handles this).
- **io.open walk**: split the path, longest-matching-prefix mount
  lookup, remaining path becomes the Twalk component list sent to that
  mount's right. one client-side ninep walker shared by every mount
  (local esp, procfs, and eventually the microvm virtio-9p root all
  use the same walker — see docs/microvm-plan.md).
- **revocation is first-class.** mount = right, so `sys.close` on the
  underlying right instantly and correctly removes it from every
  namespace holding it — no unmount syscall, no stale entry. the
  entry just becomes a dead port; a walk through it errors. plan9 has
  no equivalent instant revoke: a plan9 fd is good until its holder
  explicitly closes it, and nothing forces that. our existing
  refcount/monitor work (the reductions/memlimit era) gives
  involuntary revocation for free.

## where this goes beyond plan9, concretely

1. plan9: namespace privilege = "don't bind it and hope no one asks."
   ours: namespace privilege = "the right to ask literally doesn't
   exist in the proc's table." structurally stronger, not convention.
2. plan9: no way to time-box or forcibly revoke a mount from outside.
   ours: anyone holding a send-right to the service (or a monitor on
   it) can invalidate every downstream mount by killing the proc or
   dropping the right — cascades instantly via the refcount machinery
   already landed.
3. plan9: namespace construction is a sequence of syscalls (imperative,
   order-dependent, easy to get subtly wrong). ours: namespace is a
   single table literal passed at spawn — auditable in one glance;
   because it's data, a supervisor could statically diff two
   children's namespace tables to prove least-privilege before either
   ever runs.
4. plan9 never got real capability confinement because the Bell Labs
   fd model predates and is entangled with unix fd-inheritance-via-
   fork. we have no fork and no ambient fd table — proc birth is a
   clean slate by construction (see AGENTS.md's process and
   authority rules), so
   namespace-as-capability isn't a retrofit here, it's the only way
   it could work.

## devcap: what plan9 actually has, and why it doesn't cover this

plan9 does have a capability primitive — `#^` (devcap.c, see `cap(3)`)
— but it is narrower than a general object capability, and its
existence is evidence *for* the argument above, not against it: a
bearer token good for one thing only, changing a process's user id.

shape: a trusted process (the host owner, e.g. factotum) writes
`old@new@key` as an hmac hash into `caphash`. an untrusted process
running as `old` writes the plaintext `old@new@key` into `capuse`; if
the kernel finds a matching hash it flips that process's uid to `new`.
the hash is freed after one use or after 60 seconds. classic use:
`telnetd` proves its legitimacy to factotum, gets a capability, execs
a login shell as the target user, the shell redeems it.

two readings:

1. **it confirms the gap.** plan9's fd/namespace/bind model has no
   unforgeability property of its own, so getting one required an
   entirely separate device with its own hash table and write
   protocol — and it only patches *identity change*, not general
   object access. our rights are unforgeable everywhere, by
   construction, not through an opt-in side channel.
2. **but it names a real problem our rights don't solve yet:
   delegation across a channel that isn't live, or through an
   intermediary you don't fully trust to relay honestly.** devcap's
   whole reason to exist is that the capability must travel as a
   *string* — through exec argv, a pipe, a config file — not through
   a shared live channel. our rights, by contrast, only work while
   they stay inside the kernel's in-memory rights tables: a message
   carrying `{__right=h}` is safe because the kernel does the
   translation, and a relaying proc can forward it unread. the moment
   a capability needs to leave that world — serialized to disk so a
   restarted proc keeps its permissions, handed to a *different*
   lua-os instance across a 9p boundary that doesn't share our rights
   table, or embedded in something that must be a plain string — it
   is no longer unforgeable by construction, it is just bytes. that
   is exactly the hole devcap plugs for plan9 (kernel-checked,
   single-use, time-limited bearer hash), and it is a real future gap
   here too, not a rebuttal of the design: worth a devcap-alike
   (single-use hmac'd token, kernel-side redemption) for whichever of
   the namespace/sponsor-broker scenarios above ends up needing a
   capability to survive outside a live port.

## open questions (not yet answered)

- **runtime self-mount vs frozen-at-spawn.** does a proc get to build
  new mounts at runtime (`sys.mount(prefix, right)` into its own
  table) using rights it collects later, or are namespaces frozen at
  spawn? self-mount doesn't violate confinement (a proc still can't
  gain rights it doesn't have) but frozen-at-spawn is simpler to
  reason about and purer ("capabilities only arrive via message").
  leaning: allow self-mount, but only of rights already held — never
  allow mounting a right that wasn't received some other way.
- **default namespace for children.** parent's namespace by default,
  opt-out (plan9-style), or empty by default, opt-in (capability-
  style)? AGENTS.md's no-ambient-authority rule says empty-by-default
  is the only consistent answer: a spawn with no `ns` option gets
  nothing, must request io/serial explicitly, same as the kbd/serial
  handles today. more annoying than plan9. that's the point.
- **bootstrap / discovery.** with no ambient /net or /dev, how does a
  proc find anything to request a right to, the first time? needs
  either a bootstrap right handed at spawn (like kbd/serial today) or
  a well-known "sponsor" right every proc is born with, whose entire
  job is mediating requests for other rights — offering *nothing*
  itself except the ability to request specific, audited grants. this
  is the piece plan9 has no analogue for at all, and is probably where
  building this should actually start: a minimal sponsor/broker proc
  makes the very first mount a proc can make auditable at the point of
  request, rather than baked into an ambient, ls-able tree.

## where to start, whenever this gets picked up

1. sponsor/broker proc + protocol (the crux above) — probably its own
   design sitting before any code.
2. namespace table + longest-prefix io.open walk, spawn-time only,
   no self-mount yet.
3. port the esp fs and a synth procfs behind the same walker.
4. self-mount, once the frozen-namespace shape feels right.
5. union directories.
