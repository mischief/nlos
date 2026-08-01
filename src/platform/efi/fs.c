/* file access via the esp's simple filesystem protocol */

#include <stddef.h>
#include "efi.h"
#include "fs.h"

static EFI_GUID loaded_image_guid = { 0x5B1B31A1, 0x9562, 0x11d2,
	{ 0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B } };
static EFI_GUID sfs_guid = { 0x964e5b22, 0x6459, 0x11d2,
	{ 0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b } };
static EFI_GUID file_info_guid = { 0x09576e92, 0x6d3f, 0x11d2,
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

/* ---- enumeration and metadata ----
 *
 * a directory handle is opened exactly like a file (EFI_FILE_MODE_READ);
 * what differs is that Read() returns one EFI_FILE_INFO record per call
 * instead of bytes, and signals end-of-directory by returning success
 * with *BufferSize == 0. rewinding is SetPosition(0), which fs_seek
 * already does.
 *
 * names come back as CHAR16. we flatten to ascii and replace anything
 * outside it with '?' rather than inventing a utf-8 encoder: the esp is
 * FAT, and every path this project puts there is ascii. a name we cannot
 * represent is still listed, just not openable, which beats hiding it.
 */
static void
name_to_ascii(const CHAR16 *w, char *out, long outlen)
{
	long i;

	for (i = 0; i < outlen - 1 && w[i]; i++)
		out[i] = (w[i] < 0x80) ? (char)w[i] : '?';
	out[i] = 0;
}

/* read one directory entry. returns 1 on an entry, 0 at end of
 * directory, -1 on error.
 *
 * `f` MUST be a handle opened on a directory -- callers check with
 * fs_stat first. on a regular file Read() succeeds and returns file
 * *bytes*, which this would reinterpret as a record and report as
 * plausible-looking nonsense. it stays in bounds (the buffer is sized
 * for the largest legal name either way), so this is a correctness
 * contract rather than a safety one, but it is still a contract.
 */
int
fs_readdir(void *vf, struct fs_dirent *ent)
{
	EFI_FILE_PROTOCOL *f = vf;
	/* one record plus room for the name. the spec has no fixed
	 * maximum, but FAT long names cap at 255 CHAR16, so this is
	 * comfortably enough and avoids a malloc per entry.
	 */
	unsigned char buf[sizeof(EFI_FILE_INFO) + 256 * sizeof(CHAR16)];
	UINTN sz = sizeof buf;
	EFI_FILE_INFO *fi = (EFI_FILE_INFO *)buf;

	if (f->Read(f, &sz, buf) != EFI_SUCCESS)
		return -1;
	if (sz == 0)
		return 0;		/* end of directory */

	name_to_ascii(fi->FileName, ent->name, (long)sizeof ent->name);
	ent->size = fi->FileSize;
	ent->isdir = (fi->Attribute & EFI_FILE_DIRECTORY) != 0;
	return 1;
}

/* metadata for an already-open handle. returns 0 on success. */
int
fs_stat(void *vf, struct fs_dirent *ent)
{
	EFI_FILE_PROTOCOL *f = vf;
	unsigned char buf[sizeof(EFI_FILE_INFO) + 256 * sizeof(CHAR16)];
	UINTN sz = sizeof buf;
	EFI_FILE_INFO *fi = (EFI_FILE_INFO *)buf;

	if (f->GetInfo(f, &file_info_guid, &sz, buf) != EFI_SUCCESS)
		return -1;
	name_to_ascii(fi->FileName, ent->name, (long)sizeof ent->name);
	ent->size = fi->FileSize;
	ent->isdir = (fi->Attribute & EFI_FILE_DIRECTORY) != 0;
	return 0;
}
