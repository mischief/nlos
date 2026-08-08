# shell + namespace design (DRAFT, uncommitted)

draft from 2026-07-28. status: DESIGN ONLY, nothing built. deliberately
not committed — read it, argue with it, and decide whether it becomes a
parked doc or gets deleted.

answers: what is a "program" here, how does a pipeline work without
fork/pipe/dup2, how do paths resolve, and what does porting
`~/code/lua/os` actually cost. it builds on docs/namespace-design.md
rather than replacing it — that doc argues the capability shape of
namespaces, this one is the concrete shell-shaped subset.

## the organising idea: everything is a program, DOS-style

the shape is DOS, taken literally rather than as an aesthetic.
`COMMAND.COM` was not a special layer that approximated a program
launcher — it *was* a program, and so was everything it ran. so:

- the boot shell is a small DOS-like launcher: prompt, parse a line,
  find a program, spawn it with the right ABI, wait, report status.
- `sh.lua` is not a different design. it is **a program that happens to
  be a posix shell**, which you run from the launcher when you want one.
- `vi.lua` is a program.
- `gfx.lua` is a program that takes the display to GOP mode, runs, and
  hands it back when it exits. win.com, exactly.

this dissolves the open question the first draft ended on. posix
semantics stop being a property of the platform and become a property of
one program. concretely: **decision 5 below (subshell state inheritance)
is no longer the platform's problem.** it only matters if `sh.lua` wants
subshells, and `sh.lua` can solve it internally however it likes. the
launcher never needs to care, and neither does the kernel or the ABI.

the win.com comparison is doing real work, not just being a joke. the
display is not a mode the kernel enters — it is a capability a program
holds for its lifetime. GOP becomes an exclusive task like cons or tcp,
`gfx.lua` holds a right to it while it runs, and releases it by exiting.
no display state anywhere permanent, no mode-switching in the kernel, and
a crash in `gfx.lua` cannot leave the machine in graphics mode with
nobody driving it.

## the reframe: posix_spawn, not fork

the earlier claim that this shell "isn't portable because it needs
fork/exec" was wrong. the main external-command path in `sh/walk.lua` is:

```lua
local pid = unistd.fork()
if pid == 0 then
    signal.signal(SIGINT, SIG_DFL)     -- POSIX_SPAWN_SETSIGDEF
    stdlib.setenv(name, val, true)     -- envp
    apply_redirections(node.redirs)    -- file_actions
    unistd.execp(path, rest)           -- the exec
end
wait.wait(pid)                          -- waitpid
```

every line is a `posix_spawn` file_action or attribute. that is not an
analogy — posix_spawn exists precisely for systems that cannot fork, and
this is a textbook conversion. `sys.spawn` is already fork+exec fused and
`sys.monitor` is already waitpid.

there are only four fork sites in the whole shell. three are pure
fork-then-exec. one — the subshell in `sh/compound.lua` — runs shell code
in the child and is the only genuinely hard case.

## decision 1: a program is a lua chunk with a first-message ABI

a program is a lua source file in the namespace. it is started with
`sys.spawn`, and its first act is:

```lua
local a = thread.recv(sys.SELF)
-- a.args   = { "ls", "-l", "/tmp" }
-- a.env    = { PATH = "/bin", HOME = "/" }
-- a.cwd    = "/tmp"
-- a.stdin  = { __right = h }   -- may be nil
-- a.stdout = { __right = h }
-- a.stderr = { __right = h }
```

that is `main(argc, argv, envp)` plus fds 0/1/2, delivered as a
capability handoff instead of inherited numbers.

**the ABI is the entire contract between the launcher and everything
else, so it has to stay boring.** but note that `vi.lua` and `gfx.lua`
both need more than three streams — raw console for one, the framebuffer
for the other. those arrive as further rights in the same first message:

```lua
-- a.rawcons = { __right = h }   -- vi.lua, when granted
-- a.gop     = { __right = h }   -- gfx.lua, when granted
```

so the full shape is `{args, env, cwd, <streams>, <capabilities>}`, and
**the launcher decides what a given program is allowed to be handed.**
that is a better story than DOS ever had: `gfx.lua` can drive the display
because the shell granted it, and has no path to it otherwise. a program
that was not granted `gop` cannot go looking for it — there is no
ambient way to find it (see AGENTS.md on why `los.platform.*` is
registered per-owner, not gated by a check).

**why a message rather than inherited handles:** there is nothing to
inherit. rights do not cross `sys.spawn` — only messages carry them
(`{__right=h}`). so the first message *is* posix_spawn's file_actions
list, and the correspondence is exact rather than approximate.

exit: the chunk returns. the parent learns via `sys.monitor`.

**needs from the kernel:** `notify_exit` currently delivers
`{exit=pid, normal=bool, reason=string?}` with no numeric status, so `$?`
has nothing to read. adding a status integer is roughly five lines. this
is the only strictly required kernel change in this whole document.

## decision 2: streams speak the protocol we already have, twice

`lib/wire.lua` and `lib/cons.lua` independently invented the same shape:

```
{op="write", data=}                  -- no reply
{op="read", reply={__right=}}        -- reply is data, or nil at eof
```

standardise on it. define it once as *the* stream protocol and have
cons, wire, pipes and files all speak it. then a program writes the same
way whether stdout is a terminal, a pipe or a file, and it never learns
which.

this is what makes redirection trivial: `> f` does not need a new
mechanism, it needs stdout to be a right to a different server.

a pipe is then just a port plus a convention, with no new kernel object.

## decision 3: pipelines are ports, and this is better than fds

`a | b` becomes:

```lua
local p = sys.newport()
local bpid, bh = sys.spawn(read("/bin/b"))
sys.send(bh, { args = bargs, stdin = { __right = p },  stderr = cons })
local apid, ah = sys.spawn(read("/bin/a"))
sys.send(ah, { args = aargs, stdout = { __right = p }, stderr = cons })
sys.monitor(bpid); sys.monitor(apid)
```

no `pipe()`, no `dup2()`, no fd table, no close-the-other-end dance. the
port already refcounts: when `a` exits and its send right drops, `b`'s
read returns nil, which is eof. that falls out of the existing lifecycle
rules rather than needing SIGPIPE.

background (`&`) is the same minus the monitor. this is more Plan 9 than
the thing being ported from.

**cost, measured:** a fresh lua_State baseline is 34-40KB (see
`sys.meminfo`), so `ls | grep | wc` is three procs at ~120KB plus the
shell. `MAXPROCS` is 32, so pipeline depth is bounded by the same limit
as everything else. fine in practice, worth knowing before someone
writes a 40-stage pipeline.

## decision 4: the namespace is pure lua policy

the temptation is to make `io.open` walk a mount table. resist it —
`io.open` is vanilla liolib calling our `fopen` as plain C with no
`lua_State`, which is exactly the structural problem already documented
as a debt.

instead: **nothing forces a program to use `io.open`.** provide
`lib/ns.lua` with `open/stat/readdir/remove`, resolving paths against a
per-proc mount table, and have the shell and all utilities use that. the
mount table is a lua table; a mount is a path prefix plus a right to a
server speaking 9p-shaped messages over a port. `ninep.lua` already
serves that shape and already serves a synthetic tree.

consequences worth stating plainly:

- the namespace becomes policy, in lua, editable with a text editor —
  the strongest possible reading of "c is mechanism, lua is policy".
- `io.open` stays as the raw ESP escape hatch that boot needs, and stops
  being on the path any program takes. the liolib debt stops mattering
  without being fixed.
- a proc's namespace is inherited by being *sent* in the first message,
  which makes it a capability like everything else, and makes
  `rfork(RFNAMEG)`-style divergence the default rather than a flag.

minimum viable set: an `espfs` server proc over the existing ESP access
mounted at `/`, and `/dev/cons` bound to the cons right the shell was
given. that is enough for `ls`, `cat`, `ed` and the shell itself.

## the keystone, corrected: a Dev vtable, not 9P

an earlier version of this section had the layering backwards. it claimed
`ns.lua` was "a 9P client plus a mount table" and that espfs was a server
proc, which made 9P load-bearing on day one and inflated the work
considerably. both were wrong.

### ports are one layer below fds

a Plan 9 fd resolves to a Chan, which is `(Dev, qid, fid)` — it carries
*which file on which server*, and `read(fd, ...)` is the kernel
dispatching into that Chan's Dev. our rights table has exactly the same
structure as an fd table: per-proc small integer to kernel object. what
differs is what the handle points at. a kport is a bare message queue
with no notion of "a file", so:

	an fd = a port + a convention (which file, read/write semantics)

ports are the layer *below* fds, not the equivalent of them.

and a namespace, in Plan 9, is the `Pgrp` mount table: **names to
Chans**. we already have the bundle of handles. the missing piece is the
name map, and that is the whole gap.

### the real abstraction is Dev, and 9P is one implementation of it

the unifying interface is Plan 9's `Dev`/`devtab`: a vtable of
`walk/stat/read/write/readdir`. Chan is `(Dev, fid)`. a namespace maps
names to Chans. **9P is not the abstraction — 9P is one Dev that happens
to forward over a byte channel.**

	ns.lua:  "/"       -> espfs  backend   (direct calls to C primitives)
	         "/proc"   -> procfs backend   (pure lua, synthetic)
	         "/mnt/h"  -> 9p     backend   (client over a port right)

the same vtable, pointed the other way, is what `ninep.lua`'s server
needs. so one interface buys three things:

- the **server** adapts a backend to the 9P wire, so any backend can be
  exported — including the real ESP, where today `tcp9srv` can only serve
  a static synth tree.
- the **client** adapts the 9P wire to a backend, so anything can be
  imported.
- **`ns.lua`** maps names to backends.

that is the devpipe/devmount elegance falling out, and it does not need
9P to be involved for a local filesystem to work.

### what espfs actually is

**a backend table of about fifty lines**, wrapping the C primitives. not a
proc, not a server, no 9P. `io.open` already reaches the ESP; a shell
needs readdir, a name map and the program ABI, and none of those require
a server.

making espfs a real exclusive task buys three things, all refinements
rather than prerequisites:

- no other proc needs the disk capability, because writes route through it
- directory enumeration never becomes ambient
- the **real** ESP can be served outward, rather than the synth tree

do it later, when one of those is actually wanted.

### and the 9P client is not needed yet

it earns its place when there is something remote to mount. building it
now would mean writing the client, refactoring the server, and standing up
espfs as a proc, in order to read a file that `io.open` already reads.

it stays on the roadmap for `mount /host`, and when it lands it is *just
another backend* rather than a change to how the namespace works.

### what is actually required, then

1. **C: `fs_readdir` + `fs_stat` + `EFI_FILE_INFO`.** unchanged from
   before, and still the only platform addition. `src/fs.h` today is
   open/read/write/seek/tell/flush/close, with no enumeration and nothing
   in liolib to borrow. EFI supports it — `Read` on a directory handle
   yields `EFI_FILE_INFO` records, `GetInfo` returns metadata — it is just
   not wired up. without it there is no `ls`. ~80 lines.
   test: enumerate the ESP root from lua and find a known file.
2. **the Dev/backend interface**, defined once: `walk/stat/read/write/
   readdir`. it is a convention plus a couple of asserts, not code.
3. **`ns.lua`**: names to backends, path walking, per-proc mount table
   passed in the first message so it is inherited as a capability.
   test: resolve a path through two mounts and prove the right backend
   answers.
4. **espfs backend**: ~50 lines over the C primitives.
   test: read and list a real ESP file by path.
5. **program ABI + the launcher.**

optional, later, in any order and none blocking:

- **`ninep.lua` backend refactor.** `M.serve` currently reaches into
  `n.qid`, `n.children` and `n.data` through `nodedata`/`dirdata`/
  `nodestat`, so it can only serve synth trees. retargeting it at the
  backend interface lets it export espfs and procfs too. the existing
  `9p-protocol` test against plan9port is the regression net.
- **the 9P client**: `M.t*` encoders and R-message decoding, ~150 lines,
  mostly mirror-image of what exists. then `mount /host` is one more
  backend.
- **espfs as an exclusive task**, for the capability refinements above.

**bootstrap caveat, unchanged:** `proc_new` loadfile's `/src/thread.c`
and `require` resolves through LUA_PATH — both use `io.open` and both must
keep working. they stay outside the namespace. only programs and user data
go through `ns.lua`; do not route `require` through it.

## decision 5: the subshell inherits state as data, not as a heap

`( cd /tmp; ls )` inherits the whole interpreter state then diverges.
there is no shared heap, ever, so the child cannot fork the shell's heap.

it can be handed it. this works if — and only if — the shell keeps its
mutable state as **plain serializable tables** rather than in closures:
variables, functions-as-source, options, cwd, the mount table. then a
subshell is `sys.spawn(shell_source)` plus a first message containing
that state.

`sys.spawn` already accepts a function and `lua_dump`s it, but upvalues
do not carry values across states, so this must be data discipline in the
shell rather than a trick at the spawn site.

this is a real constraint on the port, and the one place the shell's
internals have to change rather than just its syscalls.

## vi is reachable, and needs less than expected

`~/code/lua/os/ed/` is the classic trio over one buffer: `ed.lua` (43),
`ex.lua` (41), `vi.lua` (380), `buffer.lua` (464), `terminfo.lua` (205).

the important discovery: **`terminfo.lua` is baked ANSI/VT100 escapes,
not a terminfo database.** no data files, no compiled terminfo, no
`tput`. it needs only:

| it uses | maps to |
|---|---|
| `posix.unistd` read/write | the stream protocol above |
| `posix.termio` tcgetattr/tcsetattr | a new `{op="raw"}` op in cons.lua |
| `posix.poll` | `sys.tryrecv` / `thread.alt` |
| `os.getenv("LINES"/"COLUMNS")` | env in the first message, default 80x24 |

so the only new thing vi needs is **raw mode in cons**: today cons always
runs `readline`, doing echo and line editing itself. a raw mode that
forwards single keystrokes instead is small, and cons already holds the
raw keyboard right — it is a mode flag and a second op, not new authority.

and note what this means for priorities: **vi does not need GOP.** ANSI
over com1 is enough, because the far end is a real terminal. graphics
becomes a separate want rather than a prerequisite.

`ed` needs even less — line-oriented, no cursor addressing, no raw mode.
it runs on the console we already have. it is the natural first target.

## what porting actually costs

| piece | cost | notes |
|---|---|---|
| numeric exit status | ~5 lines C | the only required kernel change |
| cons raw mode | small, lua | `{op="raw"}` + keystroke forwarding |
| stream protocol | small, lua | already exists twice; unify it |
| `lib/ns.lua` + espfs server | **medium, the keystone** | everything waits on this |
| posix shim (unistd/stat/dirent/glob) | medium, lua | over ns.lua, not over io.open |
| retarget 4 fork sites | small | mechanical, per above |
| shell state as data | medium | subshells only; a discipline change |
| replace lpeg | medium chore | 2 files: `sh/lexer.lua`, `sh/expand.lua`. we have hand-rolled 9p, dns and json parsers already |
| job control / signals | **skip** | a DOS-like shell does not want it, and we have no signals |
| `exec` builtin | skip or fake | rarely used |

lpeg is the one hard "no" from the pillars — it is a C library, and
vendoring it fails "no third-party code". the two files that use it are
lexing and word expansion, both of which are the kind of parser this repo
writes by hand routinely.

## staging

each step should leave a working machine, and each has a TAP test.

1. **numeric exit status** in `notify_exit`. tiny, unblocks `$?`.
2. **stream protocol**, defined once; cons and wire retargeted to it.
   no behaviour change, so the existing tests are the regression test.
3. **`lib/ns.lua` + espfs server**, mounted at `/`. test: read a real
   ESP file through the namespace rather than through `io.open`.
4. **program ABI + the DOS launcher**: find, spawn, wait, `$?`. then
   pipelines and redirection. test: `ls | wc -l` end to end.

that is the whole platform. steps 1-4 are the project.

everything after is independent, parallel, and does not touch the kernel
or the ABI again — which is the point of the DOS framing:

- **the easy utilities**, stdin/stdout filters: `cat`, `wc`, `tr`,
  `sort`, `head`, `tail`, `uniq`. nearly free once 4 lands.
- **`ed`**, unchanged except its io. no raw mode needed.
- **cons raw mode**, then **`vi.lua`**.
- **`sh.lua`** and its lexer rewrite, whenever someone wants posix
  semantics badly enough. decision 5 is its problem, not the platform's.
- **GOP as an exclusive task**, then **`gfx.lua`**.

none of these block each other. someone could port `cat` while someone
else does `vi`.

## open questions — not mine to decide

**resolved by the DOS framing:** whether the launcher is posix-compatible.
it is not, and does not try to be; `sh.lua` is where posix lives, as a
program. decision 5 is deferred to whoever writes it.

- **does `gfx.lua` get the framebuffer, or a drawing protocol?** handing
  a program the raw framebuffer means per-pixel writes from lua, which
  will be slow (a `Blt` for rectangles plus a text layer is the realistic
  shape). the pure answer is a `draw` task serving something
  `/dev/draw`-like over ports, which is in the dreams list already and is
  a lot more work. a first `gfx.lua` probably wants `Blt` and nothing
  else.
- **can two programs hold the display at once?** exclusive-task ownership
  says no, and that is almost certainly right — but it means the launcher
  must not spawn a second `gfx.lua` while the first lives, and needs to
  say something useful when you try.
- **is `/dev/cons` a mount or a special case?** treating the console as a
  9p-served file is the pure answer and costs a server proc; passing the
  cons right directly is cheaper and less uniform.
- **do utilities get their own lua_State each, or should trivial filters
  run as coroutines in one proc?** a State is 34-40KB and real isolation;
  a coroutine is ~nothing and none. isolation is the pillar, so per-State
  by default — but a pipeline of six `tr`s will feel it.
- **where does this leave dns/http/mcp?** if we are building a usable
  machine, they are infrastructure and stay in `lib/`. that also answers
  the open question in AGENTS.md, which is currently unresolved.
