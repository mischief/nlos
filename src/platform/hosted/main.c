/* lua-os as a linux process: the boot sequence with the machine
 * replaced by a host directory and a terminal. The order matches the
 * other platforms -- console, clock, filesystem, kernel, first proc --
 * because kernel.c depends on it: a log line needs a clock, and the
 * first proc needs a root to load from.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "blk.h"
#include "cpu.h"
#include "efi.h"
#include "fs.h"
#include "hosted.h"
#include "kernel.h"
#include "platform.h"

int hosted_display = HOSTED_HEADLESS;

/* the window, where there is one. A host window can be any size, so
 * this is a choice rather than a mode the hardware offers. */
static int guiw = 1024, guih = 768;

static void
usage(const char *argv0)
{
	fprintf(stderr,
	    "usage: %s [-r root] [-p payload] [-w] [--gui | --headless]\n"
	    "  -r root      host directory served as / (default: .)\n"
	    "  -p payload   what runs as proc 0 (default: /init.lua)\n"
	    "  -w           allow writes into the root (default: read-only)\n"
	    "  -m mb        the machine's memory in megabytes (default: 512)\n"
	    "  -d image     a file to serve as this machine's disk\n"
	    "  -n addr      the nameserver to ask (default: the host's)\n"
	    "  -s path      the services list, in the root\n"
	    "  -c dir       the writable volume served at /config\n"
	    "  --no-host-fs boot the tree built into this binary, not a\n"
	    "               directory: the machine carries its own root\n"
	    "  --gui        open a framebuffer window (1024x768)\n"
	    "  -g WxH       the window size, and --gui with it\n"
	    "  --headless   console only (default)\n", argv0);
	exit(2);
}

/* getopt would do most of this, but not the two long options, and a
 * hand loop keeps the argument grammar in one readable place.
 */
static const char *
parse_args(int argc, char **argv, const char **root, int *writable,
    unsigned long *mb, const char **disk, const char **dns,
    const char **services, const char **config)
{
	const char *payload = "/init.lua";

	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];

		if (strcmp(a, "-r") == 0 && i + 1 < argc)
			*root = argv[++i];
		else if (strcmp(a, "-p") == 0 && i + 1 < argc)
			payload = argv[++i];
		else if (strcmp(a, "-w") == 0)
			*writable = 1;
		else if (strcmp(a, "-m") == 0 && i + 1 < argc)
			*mb = strtoul(argv[++i], NULL, 10);
		else if (strcmp(a, "-d") == 0 && i + 1 < argc)
			*disk = argv[++i];
		else if (strcmp(a, "--no-host-fs") == 0)
			*root = NULL;
		else if (strcmp(a, "-n") == 0 && i + 1 < argc)
			*dns = argv[++i];
		else if (strcmp(a, "-s") == 0 && i + 1 < argc)
			*services = argv[++i];
		else if (strcmp(a, "-c") == 0 && i + 1 < argc)
			*config = argv[++i];
		else if (strcmp(a, "--gui") == 0)
			hosted_display = HOSTED_GUI;
		else if (strcmp(a, "-g") == 0 && i + 1 < argc) {
			if (sscanf(argv[++i], "%dx%d", &guiw, &guih) != 2 ||
			    guiw <= 0 || guih <= 0)
				usage(argv[0]);
			hosted_display = HOSTED_GUI;
		}
		else if (strcmp(a, "--headless") == 0)
			hosted_display = HOSTED_HEADLESS;
		else
			usage(argv[0]);
	}
	return payload;
}

/* the host's own nameserver, which is the one a guest sharing its
 * sockets should ask. Read before clearenv and before any root exists,
 * because it is the host's file and not the guest's. */
static char *
host_resolver(void)
{
	static char ip[64];
	FILE *f = fopen("/etc/resolv.conf", "r");
	char line[256];

	if (!f)
		return NULL;
	while (fgets(line, sizeof line, f)) {
		if (sscanf(line, " nameserver %63s", ip) == 1) {
			fclose(f);
			return ip;
		}
	}
	fclose(f);
	return NULL;
}

/* what SDL needs to find a display, saved across clearenv and put back
 * only when a window was asked for. The guest still inherits nothing:
 * LUA_PATH and friends are not on this list, and a headless run clears
 * the environment outright. */
static const char *const displayenv[] = {
	"DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XDG_SESSION_TYPE",
	"XAUTHORITY", "HOME", "SDL_VIDEO_DRIVER", "SDL_VIDEODRIVER", NULL
};

static void
keep_display_env(void)
{
	char *saved[16];
	int n = 0;

	for (int i = 0; displayenv[i] && n < 16; i++) {
		const char *v = getenv(displayenv[i]);

		saved[n++] = v ? strdup(v) : NULL;
	}
	clearenv();
	for (int i = 0; displayenv[i] && i < n; i++)
		if (saved[i]) {
			setenv(displayenv[i], saved[i], 1);
			free(saved[i]);
		}
}

/* the whole of a file in the served root, or null. The caller frees. */
static char *
slurp(const char *path, size_t *len)
{
	void *f = fs_open(path, 0);
	struct fs_dirent st;
	char *buf;
	long n;

	if (!f)
		return NULL;
	if (fs_stat(f, &st) != 0 || st.isdir) {
		fs_close(f);
		return NULL;
	}
	buf = malloc((size_t)st.size + 1);
	if (!buf) {
		fs_close(f);
		return NULL;
	}
	n = fs_read(f, buf, (long)st.size);
	fs_close(f);
	if (n < 0) {
		free(buf);
		return NULL;
	}
	buf[n] = '\0';
	if (len)
		*len = (size_t)n;
	return buf;
}

/* proc 0 from a file, as a chunk rather than by path, so the kernel
 * names it "init". A boot payload is injected as bytes everywhere else,
 * and a test reading its own error messages expects that name. */
static int
spawn_payload(const char *path)
{
	size_t n;
	char *buf = slurp(path, &n);
	int pid;

	if (!buf)
		return -1;
	pid = kernel_spawn_buffer(buf, n);
	free(buf);
	return pid;
}

int
main(int argc, char **argv)
{
	const char *root = ".";
	int writable = 0;
	unsigned long mb = 512;
	const char *disk = NULL;
	const char *dns = NULL;
	const char *services = "/machine/hosted/services.lua";
	const char *config = NULL;
	const char *payload = parse_args(argc, argv, &root, &writable, &mb,
	    &disk, &dns, &services, &config);
	char confbuf[512];
	char line[640];

	/* the machine's own state, which belongs with the host's other
	 * per-user state rather than in the tree being served. Read before
	 * clearenv, like the resolver.
	 */
	if (!config) {
		const char *state = getenv("XDG_STATE_HOME");
		const char *home = getenv("HOME");

		if (state && *state)
			snprintf(confbuf, sizeof confbuf, "%s/lua-os", state);
		else if (home && *home)
			snprintf(confbuf, sizeof confbuf,
			    "%s/.local/state/lua-os", home);
		else
			snprintf(confbuf, sizeof confbuf, "./luaos-config");
		config = confbuf;
	}

	if (mb == 0)
		usage(argv[0]);
	hosted_setmem((unsigned long long)mb * 1024 * 1024);

	/* before clearenv, and before the guest has any filesystem: this
	 * is the host's own resolver, which is the one a guest borrowing
	 * the host's sockets should ask.
	 */
	if (!dns)
		dns = host_resolver();
	hosted_setfwcfg("opt/org.luaos.resolver", dns);

	/* the guest inherits nothing from the shell. package.path is read
	 * from LUA_PATH where one is set, so a host with luarocks installed
	 * would put its own module tree ahead of /lib -- authority arriving
	 * by environment, which no other platform has.
	 */
	if (hosted_display == HOSTED_GUI)
		keep_display_env();
	else
		clearenv();

	console_init();
	kernel_clock_init();

	if (fs_init(root, writable) != 0) {
		fprintf(stderr, "luaos: %s is not a directory\n", root);
		return 1;
	}

	kernel_say("boot: lua-os starting (hosted)");
	if (root)
		snprintf(line, sizeof line, "root: %s (%s)", root,
		    writable ? "writable" : "read-only");
	else
		snprintf(line, sizeof line, "root: the built-in tree");
	kernel_say(line);
	snprintf(line, sizeof line, "mem: %luM", mb);
	kernel_say(line);

	if (fs_config(config) != 0)
		snprintf(line, sizeof line,
		    "config: %s cannot be made; no writable volume", config);
	else
		snprintf(line, sizeof line, "config: %s", config);
	kernel_say(line);

	/* before kernel_init: platform_have_blk decides whether blksrv is
	 * spawned, and it is asked once, there.
	 */
	if (disk) {
		if (blk_open(disk) != 0)
			kernel_say("disk: cannot open the image; no device");
		else {
			snprintf(line, sizeof line,
			    "disk: %s, %llu sectors%s", disk,
			    blk_capacity(), blk_readonly() ? " (read-only)" : "");
			kernel_say(line);
		}
	}
	/* which services this machine runs. The embedded tree installs the
	 * list as /etc/services.lua; a served working copy has no such
	 * file, since the other machines get theirs at image time, so it
	 * goes on the boot-parameter channel init.lua reads first. */
	if (root) {
		char *svc = slurp(services, NULL);

		if (svc) {
			hosted_setfwcfg("opt/org.luaos.services", svc);
			free(svc);
		} else {
			snprintf(line, sizeof line,
			    "services: %s is not there; none will start",
			    services);
			kernel_say(line);
		}
	}

	/* before kernel_init for the same reason the disk is: have_fb,
	 * have_kbd and have_ptr are asked once, there, and each decides
	 * whether a task is spawned at all. */
	if (hosted_display == HOSTED_GUI) {
		if (fb_open(guiw, guih) != 0)
			kernel_say("display: no window; running headless");
		else {
			snprintf(line, sizeof line, "display: %dx%d window",
			    guiw, guih);
			kernel_say(line);
		}
	}

	if (kernel_init() != 0) {
		kernel_say("boot: kernel_init FAILED");
		return 1;
	}
	if (spawn_payload(payload) < 0) {
		snprintf(line, sizeof line, "boot: FAILED to spawn %s", payload);
		kernel_say(line);
		return 1;
	}

	kernel_run();
	kernel_say("boot: halted (every proc exited)");
	return 0;
}

/* one cpu, so a plain static. cpu_self() is still the only way kernel.c
 * reaches it, which is what keeps that file free of the distinction.
 */
static struct cpu thecpu = { .self = &thecpu, .idx = 0, .apicid = 0 };

struct cpu *
cpu_self(void)
{
	return &thecpu;
}

struct cpu *
cpu_at(unsigned i)
{
	return i == 0 ? &thecpu : 0;
}

unsigned
platform_ncpu(void)
{
	return 1;
}

/* one cpu, so there is never another to wake, no window to close, and
 * no idle loop but the boot processor's -- which sleeps in the shim's
 * WaitForEvent instead.
 */
void
platform_wake_cpu(unsigned i)
{
	(void)i;
}

void
platform_cpu_idle(void)
{
}

void
platform_intr_off(void)
{
}

void
platform_intr_on(void)
{
}
