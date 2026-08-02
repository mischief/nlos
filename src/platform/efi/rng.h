#ifndef EFI_RNG_H
#define EFI_RNG_H

#include "lua.h"

/* Locate the firmware's EFI_RNG_PROTOCOL. Returns non-zero if one is
 * there; called once from platform_boot_extra_modules.
 */
int	efi_rng_probe(void);

int	luaopen_los_platform_rng(lua_State *L);

#endif
