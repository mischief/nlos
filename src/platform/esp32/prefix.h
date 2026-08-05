#ifndef ESP32_PREFIX_H
#define ESP32_PREFIX_H

/* Force-included ahead of every source in this component. Two things
 * that cannot be said any other way on this platform.
 *
 * 1. The lua search paths. LUA_PATH_DEFAULT contains a semicolon, and a
 *    semicolon is cmake's list separator in COMPILE_DEFINITIONS -- it
 *    split the definition into two -D flags, the second being
 *    `-D/lib/?.lua"`, so every file died in the shell rather than in
 *    the compiler. $<SEMICOLON> does not survive it either. luaconf.h
 *    guards both with #if !defined, so defining them first is the
 *    supported way in and lua/ stays vanilla.
 *
 * 2. console_write is ESP-IDF's name too: its esp_stdio component
 *    exports a function spelled exactly that, so linking ours is a
 *    multiple-definition error. Renaming here rather than in
 *    src/platform.h keeps the collision where it belongs -- it is a
 *    property of this platform's runtime, not of the interface -- and
 *    leaves the other three platforms untouched.
 */

#define LUA_PATH_DEFAULT	"/?.lua;/lib/?.lua"
#define LUA_CPATH_DEFAULT	""

#define console_write		luaos_console_write

#endif
