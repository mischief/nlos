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
   clean slate by construction (DESIGN pillars 2/3), so
   namespace-as-capability isn't a retrofit here, it's the only way
   it could work.

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
  style)? DESIGN pillar 3 (no ambient authority) says empty-by-default
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
