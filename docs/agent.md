# the agent, and what it lends its tools

`lib/agent.lua` asks a model, runs the tools it calls for, and answers.
Two programs drive it: `bin/agentui.lua` on the panel, and `bin/agent.lua`
at a terminal. The library is the same in both.

## running one

	agent what is in /bin?
	agent -m gpt-5.4 -v 'read init.lua and say what it starts'

`-v` traces each call to stderr, which is how to see what the model
actually ran rather than what it says it ran. `-k` names the key file,
`/config/openai/key` by default; `-u` an endpoint other than openai's.

## capabilities

A tool runs as a proc of its own. Nothing is ambient, so `Agent:spawn`
hands down what the tool needs at the spawn:

	caps.tcp    a right to the tcp task
	caps.dns    a right to the resolver
	caps.rand   a bytes function, drawn from per spawn

All three matter to a tool that fetches: tcp to connect, dns to turn a
name into an address, and a seed because tls will not start without
one. A caller that passes an empty table gets an agent whose tools are
offline, and `fetch` says so rather than failing at the socket.

The caller passes what it holds and no more:

	caps = {
		tcp = prog.ctx and prog.ctx.net,
		dns = prog.ctx and prog.ctx.dns,
		rand = prog.rand(),
	}

On the panel, that is whatever `/etc/dio.lua` grants the app. At a
terminal it is whatever the shell was lent.

## testing it

The hosted machine is the short loop: no board, no flash, no window.

	meson setup build-hosted -Dplatform=hosted
	ninja -C build-hosted
	build-hosted/src/platform/hosted/luaos-hosted -r .

Then `agent -v ...` at the prompt. The key is read from the machine's
`/config`, which for a hosted process is `$XDG_STATE_HOME/lua-os` unless
`-c` says otherwise, so a key at `.../lua-os/openai/key` is all the
setup there is.

A boot payload is not a shell: it has no namespace, so a test that
spawns a tool has to build one first the way `test/boot/test_prog.lua`
does. An agent test that skips that hangs in the spawn rather than
failing.
