/* luaheap under a real lua_State, on the host.
 *
 * The unit test proves the allocator is correct. This one asks the
 * question that decides whether it is worth having: what does an actual
 * lua heap cost through it, versus through what the kernel does today?
 *
 * "Today" is malloc-per-object over EFI's AllocatePool, whose own
 * per-call overhead was measured at 92 bytes (16 of ours, the rest the
 * firmware's rounding and pool metadata). That constant cannot be
 * measured on the host, so it is applied as a model to the allocation
 * counts a second, plain lua_State reports -- the counts are real, the
 * 92 is the measured figure carried over.
 */

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

#include "luaheap.h"

static int count, failed;

static int
ok(int cond, const char *name)
{
	count++;
	if (!cond)
		failed++;
	printf("%s %d - %s\n", cond ? "ok" : "not ok", count, name);
	fflush(stdout);
	return cond;
}

static void
diag(const char *fmt, ...)
{
	va_list ap;

	fputs("# ", stdout);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	fputc('\n', stdout);
	fflush(stdout);
}

/* the measured per-allocation cost of the current arrangement */
#define EFI_ALLOC_OVERHEAD 92

/* ---- chunk source ---- */

static void *
host_alloc(void *ud, size_t n)
{
	(void)ud;
	return malloc(n);
}

static void
host_free(void *ud, void *p, size_t n)
{
	(void)ud;
	(void)n;
	free(p);
}

static const struct luaheap_ops host_ops = {
	.chunk_alloc = host_alloc,
	.chunk_free = host_free,
};

/* ---- allocator A: luaheap ---- */

static void *
heap_lua_alloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
	/* lua's convention: osize is a type tag, not a size, when ptr is
	 * null. luaheap wants a real size, so normalise here exactly as
	 * kernel.c's kalloc already does.
	 */
	return luaheap_realloc(ud, ptr, ptr ? osize : 0, nsize);
}

/* ---- what sizes does lua actually ask for? ----
 *
 * Size classes are only as good as the guess behind them, so count the
 * requests instead of guessing. Exact tallies up to HIST_EXACT, which
 * covers everything a class would ever be chosen for.
 */
#define HIST_EXACT 1024

static unsigned long hist[HIST_EXACT + 1];
static unsigned long hist_big, hist_total;

static void
note_size(size_t n)
{
	hist_total++;
	if (n <= HIST_EXACT)
		hist[n]++;
	else
		hist_big++;
}

static int
cmp_count(const void *a, const void *b)
{
	size_t x = *(const size_t *)a, y = *(const size_t *)b;

	if (hist[x] != hist[y])
		return hist[x] < hist[y] ? 1 : -1;
	return x < y ? -1 : 1;
}

/* ---- allocator B: what the kernel does now ---- */

struct plain {
	size_t live, peak;
	long nlive;		/* live allocations, for the model */
	long peak_nlive;
};

static void *
plain_lua_alloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
	struct plain *s = ud;
	size_t real = ptr ? osize : 0;

	if (nsize == 0) {
		if (ptr) {
			s->live -= real;
			s->nlive--;
			free(ptr);
		}
		return 0;
	}

	note_size(nsize);

	void *q = realloc(ptr, nsize);

	if (!q)
		return 0;
	if (!ptr)
		s->nlive++;
	s->live += nsize - real;
	if (s->live > s->peak)
		s->peak = s->live;
	if (s->nlive > s->peak_nlive)
		s->peak_nlive = s->nlive;
	return q;
}

/* a workload shaped like what a proc here actually does: load and run
 * lua source, build tables and strings, make closures, collect.
 */
static const char WORKLOAD[] =
"local t = {}\n"
"for i = 1, 2000 do t[i] = { n = i, s = 'item ' .. i } end\n"
"local acc = {}\n"
"for i = 1, #t do acc[#acc + 1] = t[i].s:upper() end\n"
"table.sort(acc)\n"
"local fns = {}\n"
"for i = 1, 500 do fns[i] = function(x) return x + i end end\n"
"local sum = 0\n"
"for i = 1, #fns do sum = sum + fns[i](i) end\n"
"local buf = {}\n"
"for i = 1, 3000 do buf[#buf + 1] = tostring(i) end\n"
"local s = table.concat(buf, ',')\n"
"local parts = 0\n"
"for _ in s:gmatch('[^,]+') do parts = parts + 1 end\n"
/* pattern work per item, which is what a parser does and what the
 * generic loop above misses: gmatch allocates a state per call, sized
 * by LUA_MAXCAPTURES rather than by the pattern.
 */
"local kv = ('name=value; '):rep(8)\n"
"for i = 1, 400 do\n"
"  for k, v in kv:gmatch('(%w+)=(%w+)') do parts = parts + #k + #v end\n"
"  local a = kv:find('(%w+)=')\n"
"  parts = parts + (a or 0)\n"
"end\n"
"collectgarbage()\n"
"return #acc + sum + parts\n";

/* What comes back when a program drops something large, which a peak
 * figure cannot say. A chunk returns only when every block in it is
 * free, so the survivors allocated among the dropped thing decide how
 * much does -- and one survivor costs a whole chunk. Reported rather
 * than asserted: this is the measurement a chunk size is chosen by.
 */
static const char DROP[] =
"page, kept = {}, {}\n"
"for i = 1, 4000 do\n"
"  page[i] = { n = i, s = ('word '):rep(6) .. i }\n"
"  if i %% %d == 0 then kept[#kept + 1] = { at = i } end\n"
"end\n"
"page = nil\n";

static size_t
reclaimed(int keep)
{
	struct luaheap *h = luaheap_new(&host_ops, 0);
	lua_State *L = h ? lua_newstate(heap_lua_alloc, h) : 0;
	struct luaheap_stats st;
	char prog[512];

	if (!L) {
		return 0;
	}
	luaL_openlibs(L);
	snprintf(prog, sizeof prog, DROP, keep);
	if (luaL_dostring(L, prog) != LUA_OK) {
		lua_close(L);
		luaheap_destroy(h);
		return 0;
	}
	lua_gc(L, LUA_GCCOLLECT);
	lua_gc(L, LUA_GCCOLLECT);
	luaheap_stats(h, &st);

	size_t before = st.mapped;
	size_t got = luaheap_reclaim(h);

	luaheap_stats(h, &st);
	diag("  a survivor every %3d blocks: %zu of %zu back (%.0f%%), "
	    "%zu bytes a chunk", keep, got, before,
	    before ? 100.0 * (double)got / (double)before : 0.0,
	    st.chunks ? st.mapped / st.chunks : 0);
	lua_close(L);
	luaheap_destroy(h);
	return got;
}

static int
run(lua_State *L)
{
	if (luaL_loadstring(L, WORKLOAD) != LUA_OK)
		return 0;
	if (lua_pcall(L, 0, 1, 0) != LUA_OK)
		return 0;
	return 1;
}

int
main(void)
{
	printf("1..6\n");

	/* ---- through luaheap ---- */
	struct luaheap *h = luaheap_new(&host_ops, 0);

	if (!ok(h != 0, "heap created")) {
		printf("Bail out! no heap\n");
		return 1;
	}

	lua_State *A = lua_newstate(heap_lua_alloc, h);

	if (!ok(A != 0, "a lua_State runs on luaheap")) {
		printf("Bail out! lua_newstate failed\n");
		return 1;
	}
	luaL_openlibs(A);
	ok(run(A), "the workload completes on luaheap");

	struct luaheap_stats st;

	luaheap_stats(h, &st);

	/* ---- through the current arrangement ---- */
	struct plain ps = { 0, 0, 0, 0 };
	lua_State *B = lua_newstate(plain_lua_alloc, &ps);

	luaL_openlibs(B);
	ok(run(B), "the workload completes on plain malloc");

	/* peak is the figure that sets how many procs fit, not the
	 * end-of-run residue
	 */
	size_t now_bytes = ps.peak +
	    (size_t)ps.peak_nlive * EFI_ALLOC_OVERHEAD;

	diag("lua's own view of its heap:  %zu bytes peak", ps.peak);
	diag("live allocations at peak:    %ld", ps.peak_nlive);
	diag("");
	diag("current (modelled, 92B/alloc): %zu bytes  (%.2fx logical)",
	    now_bytes, (double)now_bytes / (double)ps.peak);
	diag("luaheap (measured):            %zu bytes  (%.2fx logical)",
	    st.mapped, (double)st.mapped / (double)st.peak);
	diag("");
	diag("luaheap peak live %zu, mapped %zu, waste %zu",
	    st.peak, st.mapped, st.waste);
	diag("chunks %lu, large blocks outstanding %lu",
	    st.chunks, st.larges);

	diag("");
	diag("waste %zu = rounding %zu + headers %zu + unused chunk %zu",
	    st.waste, st.rounding, st.headers, st.unused);

	if (st.mapped && now_bytes) {
		diag("");
		diag("ratio: luaheap is %.2fx the size of the current scheme",
		    (double)st.mapped / (double)now_bytes);
	}

	/* ---- the request profile, for choosing classes ---- */
	size_t order[HIST_EXACT];
	int n = 0;

	for (size_t i = 1; i <= HIST_EXACT; i++) {
		if (hist[i])
			order[n++] = i;
	}
	qsort(order, (size_t)n, sizeof order[0], cmp_count);

	diag("");
	diag("%lu requests total, %lu over %d bytes, %d distinct sizes below",
	    hist_total, hist_big, HIST_EXACT, n);
	diag("the twenty most-requested sizes:");
	for (int i = 0; i < n && i < 20; i++) {
		diag("  %4zu bytes  %8lu  %5.2f%%", order[i], hist[order[i]],
		    100.0 * (double)hist[order[i]] / (double)hist_total);
	}

	/* how much of every request the current classes actually waste */
	static const size_t cls[] = {
		16, 24, 32, 40, 48, 56, 64, 80, 96, 128, 192, 256, 384, 512,
	};
	unsigned long long asked = 0, served = 0;

	for (size_t i = 1; i <= HIST_EXACT; i++) {
		if (!hist[i])
			continue;

		size_t got = i;

		for (size_t k = 0; k < sizeof cls / sizeof cls[0]; k++) {
			if (i <= cls[k]) {
				got = cls[k];
				break;
			}
		}
		asked += (unsigned long long)hist[i] * i;
		served += (unsigned long long)hist[i] * got;
	}
	diag("");
	diag("current classes over all requests: asked %llu, served %llu "
	    "(%.1f%% rounding loss)", asked, served,
	    100.0 * (double)(served - asked) / (double)asked);

	ok(st.mapped < now_bytes,
	    "luaheap holds less memory than the current scheme");

	diag("");
	diag("what a dropped page hands back, at this build's chunk size:");

	static const int keeps[] = { 5, 20, 100 };
	size_t back[3];

	for (int i = 0; i < 3; i++) {
		back[i] = reclaimed(keeps[i]);
	}

	/* the sparse case only: dense survivors legitimately hand back
	 * nothing at a large chunk size, which is the finding rather than
	 * a fault
	 */
	ok(back[2] > 0, "a page dropped among sparse survivors frees chunks");

	lua_close(A);
	lua_close(B);
	luaheap_destroy(h);
	return failed ? 1 : 0;
}
