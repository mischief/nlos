# lua-os: lua on bare UEFI, hand-rolled PE header, no gnu-efi/mingw/edk2.
# image assembly and qemu invocation adapted from efivim.

CC=gcc
LD=ld
OBJCOPY=objcopy
SGDISK=/sbin/sgdisk

OVMF_CODE=/usr/share/edk2-ovmf/OVMF_CODE.fd
OVMF_VARS=/usr/share/edk2-ovmf/OVMF_VARS.fd

EFIBIN=luaos.efi
EFIIMG=luaos.img

CFLAGS=-Wall -Wextra -std=gnu11 -ffreestanding -fpic -fno-stack-protector \
	-fno-strict-aliasing -mno-red-zone -fshort-wchar -Isrc

LDFLAGS=-nostdlib -shared -Bsymbolic -znocombreloc -T src/pe.ld

OBJS=\
	build/header.o\
	build/reloc.o\
	build/main.o\

all: $(EFIBIN)

build:
	mkdir -p build

build/%.o: src/%.S | build
	$(CC) $(CFLAGS) -c -o $@ $<

build/%.o: src/%.c | build
	$(CC) $(CFLAGS) -c -o $@ $<

build/luaos.so: $(OBJS) src/pe.ld
	$(LD) $(LDFLAGS) -o $@ $(OBJS)

$(EFIBIN): build/luaos.so
	$(OBJCOPY) -O binary $< $@

# 48M gpt disk, one esp partition, fat via mtools (no root needed)
$(EFIIMG): $(EFIBIN)
	test -e $@ || (dd if=/dev/zero of=$@ bs=512 count=93750 2>/dev/null && \
		$(SGDISK) -Z $@ >/dev/null && \
		$(SGDISK) -N 1 $@ >/dev/null && \
		$(SGDISK) -t 1:ef00 $@ >/dev/null && \
		$(SGDISK) -c 1:"EFI" $@ >/dev/null && \
		mformat -i $@@@1M -v EFI -F -h 32 -t 44 -n 64 -c 1 && \
		mmd -i $@@@1M efi && \
		mmd -i $@@@1M efi/boot \
	)
	mcopy -o -i $@@@1M $(EFIBIN) ::efi/boot/bootx64.efi
	touch $@

build/OVMF_VARS.fd: | build
	cp $(OVMF_VARS) $@

qemu: $(EFIIMG) build/OVMF_VARS.fd
	qemu-system-x86_64 -enable-kvm -net none -serial mon:stdio \
		-drive if=pflash,format=raw,readonly=on,file=$(OVMF_CODE) \
		-drive if=pflash,format=raw,file=build/OVMF_VARS.fd \
		-drive format=raw,file=$(EFIIMG)

clean:
	rm -rf build $(EFIBIN) $(EFIIMG)

.PHONY: all qemu clean
.DELETE_ON_ERROR:
