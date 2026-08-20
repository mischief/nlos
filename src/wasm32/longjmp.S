// the throw half of sjlj.c. Only assembly can name a tag, and
// __c_longjmp is the tag the compiler's catch is written against.
// Defined here rather than imported: this module is the whole machine.

	.tagtype	__c_longjmp i32
	.functype	__luaos_longjmp_arg (i32, i32) -> (i32)

	.text
	.globl	__wasm_longjmp
	.type	__wasm_longjmp,@function
__wasm_longjmp:
	.functype	__wasm_longjmp (i32, i32) -> ()
	local.get	0
	local.get	1
	call	__luaos_longjmp_arg
	throw	__c_longjmp
	end_function

	.globl	__c_longjmp
	.section	.tag.__c_longjmp,"",@
__c_longjmp:
