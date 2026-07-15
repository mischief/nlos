/* file access via the esp's simple filesystem protocol */

#include <stddef.h>
#include "efi.h"
#include "fs.h"

static EFI_GUID loaded_image_guid = { 0x5B1B31A1, 0x9562, 0x11d2,
	{ 0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B } };
static EFI_GUID sfs_guid = { 0x964e5b22, 0x6459, 0x11d2,
	{ 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } };

static EFI_FILE_PROTOCOL *rootdir;

int
fs_init(void)
{
	EFI_LOADED_IMAGE_PROTOCOL *li;
	EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *sfs;

	if (BS->HandleProtocol(self_image, &loaded_image_guid,
	    (void **)&li) != EFI_SUCCESS)
		return -1;
	if (BS->HandleProtocol(li->DeviceHandle, &sfs_guid,
	    (void **)&sfs) != EFI_SUCCESS)
		return -1;
	if (sfs->OpenVolume(sfs, &rootdir) != EFI_SUCCESS)
		return -1;
	return 0;
}

void *
fs_open(const char *path, int write)
{
	EFI_FILE_PROTOCOL *f;
	CHAR16 wpath[256];
	UINT64 mode = EFI_FILE_MODE_READ;
	int i;

	if (rootdir == 0)
		return 0;
	for (i = 0; path[i] && i < 255; i++)
		wpath[i] = path[i] == '/' ? '\\' : (CHAR16)path[i];
	wpath[i] = 0;

	if (write)
		mode |= EFI_FILE_MODE_WRITE | EFI_FILE_MODE_CREATE;
	if (rootdir->Open(rootdir, &f, wpath, mode, 0) != EFI_SUCCESS)
		return 0;
	if (write)
		f->SetPosition(f, 0);
	return f;
}

long
fs_read(void *vf, void *buf, long n)
{
	EFI_FILE_PROTOCOL *f = vf;
	UINTN sz = n;

	if (f->Read(f, &sz, buf) != EFI_SUCCESS)
		return -1;
	return (long)sz;
}

long
fs_write(void *vf, const void *buf, long n)
{
	EFI_FILE_PROTOCOL *f = vf;
	UINTN sz = n;

	if (f->Write(f, &sz, (void *)buf) != EFI_SUCCESS)
		return -1;
	return (long)sz;
}

int
fs_seek(void *vf, long pos, int whence)
{
	EFI_FILE_PROTOCOL *f = vf;
	UINT64 cur, base = 0;

	switch (whence) {
	case 0:	/* SEEK_SET */
		base = 0;
		break;
	case 1:	/* SEEK_CUR */
		if (f->GetPosition(f, &cur) != EFI_SUCCESS)
			return -1;
		base = cur;
		break;
	case 2:	/* SEEK_END */
		base = 0xFFFFFFFFFFFFFFFFULL;	/* efi: end of file */
		if (f->SetPosition(f, base) != EFI_SUCCESS)
			return -1;
		if (f->GetPosition(f, &cur) != EFI_SUCCESS)
			return -1;
		base = cur;
		break;
	default:
		return -1;
	}
	if (f->SetPosition(f, base + pos) != EFI_SUCCESS)
		return -1;
	return 0;
}

long
fs_tell(void *vf)
{
	EFI_FILE_PROTOCOL *f = vf;
	UINT64 pos;

	if (f->GetPosition(f, &pos) != EFI_SUCCESS)
		return -1;
	return (long)pos;
}

void
fs_close(void *vf)
{
	EFI_FILE_PROTOCOL *f = vf;

	f->Close(f);
}

int
fs_flush(void *vf)
{
	EFI_FILE_PROTOCOL *f = vf;

	return f->Flush(f) == EFI_SUCCESS ? 0 : -1;
}
