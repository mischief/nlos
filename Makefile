# lua-os: lua on bare UEFI, hand-rolled PE header, no gnu-efi/mingw/edk2.
# freestanding: only our include/ plus the compiler's own headers.

ARCH=x86_64

CC=gcc
LD=ld
OBJCOPY=objcopy
SGDISK=/sbin/sgdisk

OVMF_CODE=/usr/share/edk2-ovmf/OVMF_CODE.fd
OVMF_VARS=/usr/share/edk2-ovmf/OVMF_VARS.fd

EFIBIN=luaos.efi
EFIIMG=luaos.img

GCCINC=$(shell $(CC) -print-file-name=include)

LUAPATH=-DLUA_PATH_DEFAULT='"/?.lua;/lib/?.lua"' -DLUA_CPATH_DEFAULT='""'
CFLAGS=$(LUAPATH) -O2 -Wall -std=gnu11 -ffreestanding -fpic -fno-stack-protector \
	-fno-strict-aliasing -mno-red-zone -msse4.1 -fshort-wchar \
	-fvisibility=hidden -nostdinc -Iinclude -isystem $(GCCINC) -Isrc -Ilua

LDFLAGS=-nostdlib -shared -Bsymbolic -znocombreloc -T src/pe.ld

OBJS=\
	build/$(ARCH)/header.o\
	build/$(ARCH)/reloc.o\
	build/$(ARCH)/setjmp.o\
	build/$(ARCH)/machine.o\
	build/$(ARCH)/uart.o\
	build/$(ARCH)/math.o\
	build/libc/string.o\
	build/libc/stdlib.o\
	build/libc/stdio.o\
	build/libc/vsnprintf.o\
	build/libc/locale.o\
	build/libc/time.o\
	build/libc/math.o\
	build/console.o\
	build/fs.o\
	build/kernel.o\
	build/los.o\
	build/malloc.o\
	build/linit.o\
	build/main.o\

LUA_SRC=$(filter-out lua/lua.c lua/luac.c lua/onelua.c lua/linit.c \
	lua/loslib.c lua/ltests.c,\
	$(wildcard lua/*.c))
LUA_OBJS=$(patsubst lua/%.c,build/lua/%.o,$(LUA_SRC))

all: $(EFIBIN)

build build/$(ARCH) build/libc build/lua:
	mkdir -p $@

build/$(ARCH)/%.o: src/$(ARCH)/%.S | build/$(ARCH)
	$(CC) $(CFLAGS) -c -o $@ $<

build/$(ARCH)/%.o: src/$(ARCH)/%.c | build/$(ARCH)
	$(CC) $(CFLAGS) -c -o $@ $<

build/libc/%.o: src/libc/%.c | build/libc
	$(CC) $(CFLAGS) -c -o $@ $<

build/lua/%.o: lua/%.c | build/lua
	$(CC) $(CFLAGS) -c -o $@ $<

build/%.o: src/%.c | build
	$(CC) $(CFLAGS) -c -o $@ $<

build/luaos.so: $(OBJS) $(LUA_OBJS) src/pe.ld
	$(LD) $(LDFLAGS) -o $@ $(OBJS) $(LUA_OBJS)

$(EFIBIN): build/luaos.so
	$(OBJCOPY) -O binary $< $@

# 48M gpt disk, one esp partition, fat via mtools (no root needed)
$(EFIIMG): $(EFIBIN) init.lua prelude.lua lib/ninep.lua
	test -e $@ || (dd if=/dev/zero of=$@ bs=512 count=93750 2>/dev/null && \
		$(SGDISK) -Z $@ >/dev/null && \
		$(SGDISK) -N 1 $@ >/dev/null && \
		$(SGDISK) -t 1:ef00 $@ >/dev/null && \
		$(SGDISK) -c 1:"EFI" $@ >/dev/null && \
		mformat -i $@@@1M -v EFI -F -h 32 -t 44 -n 64 -c 1 && \
		mmd -i $@@@1M efi && \
		mmd -i $@@@1M efi/boot && \
		mmd -i $@@@1M lib \
	)
	mcopy -o -i $@@@1M $(EFIBIN) ::efi/boot/bootx64.efi
	mcopy -o -i $@@@1M init.lua ::init.lua
	mcopy -o -i $@@@1M prelude.lua ::prelude.lua
	mcopy -o -i $@@@1M lib/ninep.lua ::lib/ninep.lua
	touch $@

build/OVMF_VARS.fd: | build
	cp $(OVMF_VARS) $@

qemu: $(EFIIMG) build/OVMF_VARS.fd
	qemu-system-x86_64 -nographic -enable-kvm -cpu max -net none -serial mon:stdio \
		-drive if=pflash,format=raw,readonly=on,file=$(OVMF_CODE) \
		-drive if=pflash,format=raw,file=build/OVMF_VARS.fd \
		-drive format=raw,file=$(EFIIMG)

clean:
	rm -rf build $(EFIBIN) $(EFIIMG)

.PHONY: all qemu clean
.DELETE_ON_ERROR:
