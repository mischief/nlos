/* USB host: what is plugged in, and what it says it is.
 *
 * The S3's OTG controller in host mode. Two board facts gate it, which
 * is why it is a config option and why it is off by default: the port
 * must source 5V on VBUS, and it must not be the console.
 */

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/stream_buffer.h>

#include "esp32.h"
#include "platform.h"
#include "kernel.h"

/* the header comes with the managed component, which is fetched only
 * for a chip that has the controller
 */
#if CONFIG_LUAOS_USB_HOST

#include <usb/usb_host.h>

#define USB_TASK_STACK 4096

static usb_host_client_handle_t client;
static usb_device_handle_t device;

/* the active configuration as bytes, which is what lib/usb.lua parses.
 * Kept rather than pointed at: the descriptor belongs to the stack, and
 * a device that leaves takes it with it.
 */
static uint8_t desc[512];
static int desclen;

static void playstop(void);

/* kernel_say takes a finished line */
static void
sayf(const char *fmt, ...)
{
	char line[128];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(line, sizeof(line), fmt, ap);
	va_end(ap);
	kernel_say(line);
}

/* the descriptor as bytes, which is what a parser above wants. A device
 * that is not the one expected is diagnosed from this and nothing else.
 */
static void
dumpcfg(const usb_config_desc_t *cfg)
{
	const uint8_t *p = (const uint8_t *)cfg;
	int n = cfg->wTotalLength, i;
	char line[3 * 16 + 1];

	for (i = 0; i < n; i += 16) {
		int j, w = 0;

		for (j = i; j < i + 16 && j < n; j++)
			w += snprintf(line + w, sizeof(line) - w, "%02x ", p[j]);
		sayf("usb: cfg %04x %s", i, line);
	}
}

static void
opened(uint8_t addr)
{
	usb_device_handle_t dev;
	const usb_device_desc_t *dd;
	const usb_config_desc_t *cfg;

	if (usb_host_device_open(client, addr, &dev) != ESP_OK) {
		sayf("usb: cannot open device %u", addr);
		return;
	}
	device = dev;

	if (usb_host_get_device_descriptor(dev, &dd) == ESP_OK)
		sayf("usb: %u vid %04x pid %04x class %02x/%02x usb %04x",
		    addr, dd->idVendor, dd->idProduct, dd->bDeviceClass,
		    dd->bDeviceSubClass, dd->bcdUSB);

	if (usb_host_get_active_config_descriptor(dev, &cfg) == ESP_OK) {
		sayf("usb: %u config %u interfaces, %u bytes",
		    addr, cfg->bNumInterfaces, cfg->wTotalLength);
		dumpcfg(cfg);

		desclen = cfg->wTotalLength;
		if (desclen > (int)sizeof(desc))
			desclen = sizeof(desc);
		memcpy(desc, cfg, desclen);
	}
}

static void
evcb(const usb_host_client_event_msg_t *msg, void *arg)
{
	(void)arg;

	switch (msg->event) {
	case USB_HOST_CLIENT_EVENT_NEW_DEV:
		opened(msg->new_dev.address);
		break;
	case USB_HOST_CLIENT_EVENT_DEV_GONE:
		kernel_say("usb: device gone");
		playstop();
		device = NULL;
		desclen = 0;
		break;
	default:
		break;
	}
}

/* ---- playback ----
 *
 * The bus asks every millisecond whether anybody has anything, and
 * nothing may be late. A packet with no audio behind it carries
 * silence rather than nothing, which is a click and not a stall.
 */

#define NXFER 4			/* transfers in flight */
#define NPKT 4			/* milliseconds a transfer */
#define RINGMS 200		/* what the ring holds, in milliseconds */

static usb_transfer_t *xfer[NXFER];
static StreamBufferHandle_t pcm;
static int playing;
static int playpkt;		/* bytes a millisecond */
static unsigned long underruns;

/* refill and resubmit. Runs on the client task, so the stream buffer is
 * read here and written by whatever proc is playing.
 */
static void
refill(usb_transfer_t *t)
{
	int i, off = 0;

	for (i = 0; i < NPKT; i++) {
		size_t got = 0;

		if (pcm)
			got = xStreamBufferReceive(pcm, t->data_buffer + off,
			    playpkt, 0);

		if ((int)got < playpkt) {
			memset(t->data_buffer + off + got, 0, playpkt - got);
			underruns++;
		}
		t->isoc_packet_desc[i].num_bytes = playpkt;
		off += playpkt;
	}
	t->num_bytes = off;

	if (usb_host_transfer_submit(t) != ESP_OK)
		playing = 0;
}

static void
played(usb_transfer_t *t)
{
	if (playing)
		refill(t);
}

static void
playstop(void)
{
	int i;

	playing = 0;

	for (i = 0; i < NXFER; i++) {
		if (xfer[i]) {
			usb_host_transfer_free(xfer[i]);
			xfer[i] = NULL;
		}
	}

	if (pcm) {
		vStreamBufferDelete(pcm);
		pcm = NULL;
	}
}

/* UAC1 asks for its rate on the endpoint, not the interface: SET_CUR of
 * the sampling frequency control, three bytes little endian.
 */
static int
setrate(int ep, int rate)
{
	usb_transfer_t *t;
	int rc = -1;

	if (usb_host_transfer_alloc(sizeof(usb_setup_packet_t) + 3, 0, &t) != ESP_OK)
		return -1;

	usb_setup_packet_t *s = (usb_setup_packet_t *)t->data_buffer;

	s->bmRequestType = 0x22;	/* class, to an endpoint */
	s->bRequest = 0x01;		/* SET_CUR */
	s->wValue = 0x0100;		/* sampling frequency */
	s->wIndex = ep;
	s->wLength = 3;
	t->data_buffer[8] = rate & 0xff;
	t->data_buffer[9] = (rate >> 8) & 0xff;
	t->data_buffer[10] = (rate >> 16) & 0xff;
	t->num_bytes = sizeof(usb_setup_packet_t) + 3;
	t->device_handle = device;
	t->bEndpointAddress = 0;
	t->callback = NULL;
	t->timeout_ms = 1000;

	if (usb_host_transfer_submit_control(client, t) == ESP_OK)
		rc = 0;
	usb_host_transfer_free(t);
	return rc;
}

int
platform_usb_play(int itf, int alt, int ep, int packet, int rate)
{
	int i;

	if (!device || packet <= 0)
		return -1;

	playstop();

	if (usb_host_interface_claim(client, device, itf, alt) != ESP_OK) {
		kernel_say("usb: cannot claim the audio interface");
		return -1;
	}

	if (setrate(ep, rate) != 0)
		kernel_say("usb: the device refused the rate; playing anyway");

	pcm = xStreamBufferCreate(packet * RINGMS, 1);
	if (!pcm)
		return -1;

	playpkt = packet;
	underruns = 0;
	playing = 1;

	for (i = 0; i < NXFER; i++) {
		if (usb_host_transfer_alloc(packet * NPKT, NPKT, &xfer[i]) != ESP_OK) {
			playstop();
			return -1;
		}
		xfer[i]->device_handle = device;
		xfer[i]->bEndpointAddress = ep;
		xfer[i]->callback = played;
		xfer[i]->timeout_ms = 0;
		refill(xfer[i]);
	}
	sayf("usb: playing on endpoint %02x, %d bytes a ms", ep, packet);
	return 0;
}

/* what was taken. A short answer means the ring is full, which is the
 * one thing a caller has to react to: it is the pace, and outrunning it
 * is how the audio arrives late.
 */
int
platform_usb_write(const void *p, int n)
{
	if (!playing || !pcm)
		return -1;
	return (int)xStreamBufferSend(pcm, p, n, 0);
}

void
platform_usb_stop(void)
{
	playstop();
}

int
platform_usb_desc(void *p, int max)
{
	int n = desclen < max ? desclen : max;

	if (n > 0)
		memcpy(p, desc, n);
	return n;
}

unsigned long
platform_usb_underruns(void)
{
	return underruns;
}

/* One task drives both halves. The library wants its own event pump and
 * the client wants another; neither may run on a lua-os thread, because
 * both block in FreeRTOS rather than in the scheduler.
 */
static void
usbtask(void *arg)
{
	usb_host_config_t hcfg = { .intr_flags = ESP_INTR_FLAG_LEVEL1 };
	usb_host_client_config_t ccfg = {
		.is_synchronous = false,
		.max_num_event_msg = 5,
		.async = { .client_event_callback = evcb, .callback_arg = NULL },
	};

	(void)arg;

	if (usb_host_install(&hcfg) != ESP_OK) {
		kernel_say("usb: host_install failed");
		vTaskDelete(NULL);
		return;
	}

	if (usb_host_client_register(&ccfg, &client) != ESP_OK) {
		kernel_say("usb: client_register failed");
		vTaskDelete(NULL);
		return;
	}
	kernel_say("usb: host up, waiting for a device");

	for (;;) {
		uint32_t flags;

		usb_host_lib_handle_events(10 / portTICK_PERIOD_MS, &flags);
		usb_host_client_handle_events(client, 10 / portTICK_PERIOD_MS);
	}
}

/* once: the controller has no second instance, and a second caller is
 * asking for what is already running.
 */
int
platform_usbhost(void)
{
	static int started;

	if (started)
		return 1;
	started = 1;
	xTaskCreate(usbtask, "usb", USB_TASK_STACK, NULL, 5, NULL);
	return 1;
}

#else

/* a chip without the controller, or a board that did not ask for it */
int
platform_usbhost(void)
{
	return 0;
}

int
platform_usb_desc(void *p, int max)
{
	(void)p;
	(void)max;
	return 0;
}

int
platform_usb_play(int itf, int alt, int ep, int packet, int rate)
{
	(void)itf;
	(void)alt;
	(void)ep;
	(void)packet;
	(void)rate;
	return -1;
}

int
platform_usb_write(const void *p, int n)
{
	(void)p;
	(void)n;
	return -1;
}

void
platform_usb_stop(void)
{
}

unsigned long
platform_usb_underruns(void)
{
	return 0;
}

#endif
