/* los.inet -- the one piece of the ip stack that is not policy.
 *
 * Everything else about a packet is a decision: which address to use,
 * whether to arp, what to do with a datagram nobody is bound to. Those
 * live in Lua because they are the parts worth reading and changing.
 * The internet checksum is not a decision -- it is RFC 1071's sum,
 * fixed since 1988, the same for every packet -- and it is the only
 * thing on the path whose cost grows with the payload.
 *
 * That combination is what puts it here. Measured over loopback, where
 * no device or wire is in the way (test/boot/microvm_udpbench.lua):
 *
 *	payload    round trip   checksum   share
 *	     1B        38.5us      6.3us   16.5%
 *	  1400B       444.6us    378.3us   85.1%
 *
 * Four per round trip -- udp4 computes one encoding and verifies
 * another decoding, in each direction -- and the Lua loop read a
 * string.unpack per two bytes, so a full-sized datagram was 700 unpacks
 * done four times over.
 *
 * lib/ip4.lua keeps its own implementation and prefers this when it is
 * there. Not defensiveness: tools/arp-lan.lua drives the same modules
 * from the host under an ordinary lua5.4, where no part of this kernel
 * exists, and the two are checked against each other by
 * test/boot/test_checksum.lua.
 */

#include <stddef.h>

#include "lua.h"
#include "lauxlib.h"

/* RFC 1071: the one's complement of the one's complement sum of the
 * data taken as big-endian 16-bit words, with a final odd byte treated
 * as the high half of a word.
 *
 * Deliberately the plain form and not one of the word-at-a-time
 * variants. The carries fold once at the end rather than per addition,
 * which is what makes that valid, and the accumulator cannot overflow
 * short of 2^48 bytes of input -- MAXMSG is 64KiB.
 */
static int
l_checksum(lua_State *L)
{
	size_t n = 0;
	const char *s = luaL_checklstring(L, 1, &n);
	const unsigned char *p = (const unsigned char *)s;
	unsigned long long sum = (unsigned long long)luaL_optinteger(L, 2, 0);
	size_t i = 0;

	while (i + 1 < n) {
		sum += ((unsigned long long)p[i] << 8) | p[i + 1];
		i += 2;
	}
	if (i < n)
		sum += (unsigned long long)p[i] << 8;

	while (sum > 0xffff)
		sum = (sum & 0xffff) + (sum >> 16);

	lua_pushinteger(L, (lua_Integer)((~sum) & 0xffff));
	return 1;
}

static const luaL_Reg inetlib[] = {
	{ "checksum", l_checksum },
	{ NULL, NULL },
};

int	luaopen_los_inet(lua_State *L);

int
luaopen_los_inet(lua_State *L)
{
	luaL_newlib(L, inetlib);
	return 1;
}
