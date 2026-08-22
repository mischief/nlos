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
#include <freertos/semphr.h>

#include <esp_heap_caps.h>

#include "esp32.h"
#include "platform.h"
#include "kernel.h"

/* the header comes with the managed component, which is fetched only
 * for a chip that has the controller
 */
#if CONFIG_LUAOS_USB_HOST

#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
#include <driver/usb_serial_jtag.h>
#endif
#include <usb/usb_host.h>

#define USB_TASK_STACK 8192

static usb_host_client_handle_t client;
static usb_device_handle_t device;

/* the active configuration as bytes, which is what lib/usb.lua parses.
 * Kept rather than pointed at: the descriptor belongs to the stack, and
 * a device that leaves takes it with it.
 */
static uint8_t desc[512];
static int desclen;

static void playstop(int wait);

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
		playstop(0);
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

/* One writer, one reader, and free-running counters: the playing proc
 * moves `head` and the pump moves `tail`, so neither needs a lock.
 */
static usb_transfer_t *xfer[NXFER];
static uint8_t *pcm;
static int pcmsize;
static volatile unsigned head, tail;

static int
ringput(const uint8_t *p, int n)
{
	unsigned h = head;
	int room = pcmsize - (int)(h - tail);
	int at = h & (pcmsize - 1), first;

	if (n > room)
		n = room;
	first = n < pcmsize - at ? n : pcmsize - at;
	memcpy(pcm + at, p, first);
	memcpy(pcm, p + first, n - first);
	head = h + n;
	return n;
}

static int
ringget(uint8_t *p, int n)
{
	unsigned t = tail;
	int have = (int)(head - t);
	int at = t & (pcmsize - 1), first;

	if (n > have)
		n = have;
	first = n < pcmsize - at ? n : pcmsize - at;
	memcpy(p, pcm + at, first);
	memcpy(p + first, pcm, n - first);
	tail = t + n;
	return n;
}

static int playing;
static int playitf = -1;	/* claimed, and to be given back */
static volatile int inflight;	/* submitted, and not yet answered for */
static volatile uint8_t idle[NXFER];	/* answered for, and waiting to go out */
static volatile unsigned beat;	/* pump turns, so a stop can see one */
static int playep;		/* the endpoint the transfers are on */
static volatile int priming;	/* filling the ring before the first packet */
static int primed;		/* pump turns spent waiting for it */
static int playpkt;		/* bytes a millisecond */
static unsigned long underruns;

/* refill and resubmit, answering whether it went back out */
static int
refill(usb_transfer_t *t)
{
	int i, off = 0;

	for (i = 0; i < NPKT; i++) {
		int got = 0;

		if (pcm)
			got = ringget(t->data_buffer + off, playpkt);

		/* silence before the first byte is the prefill, not a gap */
		if (got < playpkt) {
			memset(t->data_buffer + off + got, 0, playpkt - got);
			if (head)
				underruns++;
		}
		t->isoc_packet_desc[i].num_bytes = playpkt;
		off += playpkt;
	}
	t->num_bytes = off;

	if (usb_host_transfer_submit(t) == ESP_OK)
		return 1;

	playing = 0;
	return 0;
}

/* A transfer may not go back out from inside the event handler: the
 * same loop would dequeue what was just enqueued. The pump submits it.
 */
static void
played(usb_transfer_t *t)
{
	inflight--;
	idle[(int)(intptr_t)t->context] = 1;
}

/* what the callbacks left, submitted from the task the handler is not
 * running on. Answers how many went out.
 */
static void
pump(void)
{
	int i;

	/* a file shorter than the fill mark never reaches it, so the wait
	 * is bounded and a short one simply starts with what it has
	 */
	if (priming && ++primed > 50)
		priming = 0;

	for (i = 0; i < NXFER; i++) {
		if (!idle[i] || priming)
			continue;
		idle[i] = 0;
		if (playing && refill(xfer[i]))
			inflight++;
	}
	beat++;
}

/* `wait` is false only where the device has already left. Two beats,
 * because one may have read `playing` before it was cleared.
 */
static void
playstop(int wait)
{
	unsigned b = beat;
	int i;

	playing = 0;

	for (i = 0; wait && i < 400; i++) {
		if (inflight == 0 && beat > b + 1)
			break;
		vTaskDelay(pdMS_TO_TICKS(5));
	}
	inflight = 0;
	priming = 0;

	/* a streaming pipe is busy until it is halted, and an interface
	 * whose pipes are busy will not go back
	 */
	if (wait && device && playep) {
		usb_host_endpoint_halt(device, playep);
		usb_host_endpoint_flush(device, playep);
	}
	playep = 0;

	if (playitf >= 0) {
		esp_err_t e = device ? usb_host_interface_release(client,
		    device, playitf) : ESP_OK;

		if (e != ESP_OK)
			sayf("usb: release itf %d: %s", playitf,
			    esp_err_to_name(e));
		playitf = -1;
	}

	for (i = 0; i < NXFER; i++) {
		if (xfer[i]) {
			usb_host_transfer_free(xfer[i]);
			xfer[i] = NULL;
		}
	}

	if (pcm) {
		heap_caps_free(pcm);
		pcm = NULL;
	}
	head = tail = 0;
}

/* a control transfer answers on the client task, so it is waited for */
static SemaphoreHandle_t ctldone;

static void
ctlcb(usb_transfer_t *t)
{
	xSemaphoreGive((SemaphoreHandle_t)t->context);
}

/* UAC1 asks for its rate on the endpoint, not the interface: SET_CUR of
 * the sampling frequency control, three bytes little endian.
 */
static int
setrate(int ep, int rate)
{
	usb_transfer_t *t;
	int rc = -1;

	if (!ctldone && !(ctldone = xSemaphoreCreateBinary()))
		return -1;

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
	t->callback = ctlcb;
	t->context = ctldone;
	t->timeout_ms = 1000;

	if (usb_host_transfer_submit_control(client, t) != ESP_OK) {
		usb_host_transfer_free(t);
		return -1;
	}

	/* the stack owns it until the callback runs, so a timeout frees nothing */
	if (xSemaphoreTake(ctldone, pdMS_TO_TICKS(2000)) != pdTRUE)
		return -1;

	if (t->status == USB_TRANSFER_STATUS_COMPLETED)
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

	playstop(1);

	esp_err_t e = usb_host_interface_claim(client, device, itf, alt);

	if (e != ESP_OK) {
		sayf("usb: claim itf %d alt %d: %s", itf, alt,
		    esp_err_to_name(e));
		return -1;
	}
	playitf = itf;

	if (setrate(ep, rate) != 0)
		kernel_say("usb: the device refused the rate; playing anyway");

	/* PSRAM: nothing here runs in an interrupt, and 48kHz stereo
	 * wants more of the internal kind than the machine can spare
	 */
	/* a power of two, so the index stays continuous where the
	 * counters wrap and a whole ring's worth is not lost there
	 */
	for (pcmsize = 1024; pcmsize < packet * RINGMS; pcmsize *= 2)
		;
	pcm = heap_caps_malloc(pcmsize, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
	if (!pcm)
		pcm = heap_caps_malloc(pcmsize, MALLOC_CAP_8BIT);

	if (!pcm) {
		sayf("usb: no room for a %d byte ring", packet * RINGMS);
		playstop(0);
		return -1;
	}

	playpkt = packet;
	playep = ep;
	underruns = 0;
	playing = 1;

	for (i = 0; i < NXFER; i++) {
		if (usb_host_transfer_alloc(packet * NPKT, NPKT, &xfer[i]) != ESP_OK) {
			sayf("usb: no room for transfer %d of %d bytes", i,
			    packet * NPKT);
			playstop(1);
			return -1;
		}
		xfer[i]->device_handle = device;
		xfer[i]->bEndpointAddress = ep;
		xfer[i]->callback = played;
		xfer[i]->timeout_ms = 0;
		xfer[i]->context = (void *)(intptr_t)i;
		idle[i] = 1;
	}
	priming = 1;
	primed = 0;
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
	int took;

	if (!playing || !pcm)
		return -1;
	took = ringput(p, n);

	/* the stream starts on a full ring, not an empty one: a reader
	 * that has to stay ahead from the first packet has no slack
	 */
	if (priming && (int)(head - tail) >= pcmsize / 2)
		priming = 0;
	return took;
}

void
platform_usb_stop(void)
{
	playstop(1);
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

		usb_host_lib_handle_events(0, &flags);
		usb_host_client_handle_events(client, pdMS_TO_TICKS(2));
		pump();
	}
}

/* once: the controller has no second instance, and a second caller is
 * asking for what is already running.
 */
/* the console is on the same port where sdkconfig says so, and
 * starting the host takes it until the next boot
 */
int
platform_usb_isconsole(void)
{
#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
	return 1;
#else
	return 0;
#endif
}

/* is a host talking to us on that port right now? A host sends a
 * start-of-frame every millisecond and IDF watches for them, so this
 * is "the console is in use" -- which is what makes claiming the port
 * expensive. With no host there, that console is already nobody's.
 */
int
platform_usb_hostattached(void)
{
#if CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG
	return usb_serial_jtag_is_connected() ? 1 : 0;
#else
	return 0;
#endif
}

int
platform_usb_have(void)
{
	return 1;
}

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
platform_usb_have(void)
{
	return 0;
}
int
platform_usb_isconsole(void)
{
	return 0;
}

int
platform_usb_hostattached(void)
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
