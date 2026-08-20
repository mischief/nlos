/* setjmp/longjmp for wasm, which has no stack to save.
 * -mllvm -wasm-enable-sjlj rewrites every function holding a setjmp
 * into a try_table and calls these. A jmp_buf names an invocation and
 * a call site; label is nonzero everywhere, so zero means "not this
 * frame" and the compiler's catch rethrows.
 */

#include <stdint.h>

struct env {
	void *invocation;
	uint32_t label;
};

/* what travels with the thrown __c_longjmp tag. One is enough: a throw
 * reaches its catch before anything else can longjmp.
 */
static struct {
	void *env;
	int val;
} throwarg;

void	__wasm_setjmp(void *env, uint32_t label, void *invocation);
uint32_t __wasm_setjmp_test(void *env, void *invocation);
void	*__luaos_longjmp_arg(void *env, int val);

void
__wasm_setjmp(void *envp, uint32_t label, void *invocation)
{
	struct env *e = envp;

	e->invocation = invocation;
	e->label = label;
}

uint32_t
__wasm_setjmp_test(void *envp, void *invocation)
{
	struct env *e = envp;

	return e && e->invocation == invocation ? e->label : 0;
}

/* a longjmp of 0 arrives as 1: that is how setjmp says "by longjmp". */
void *
__luaos_longjmp_arg(void *env, int val)
{
	throwarg.env = env;
	throwarg.val = val ? val : 1;
	return &throwarg;
}
