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

#include "esp32.h"
#include "kernel.h"

/* the header comes with the managed component, which is fetched only
 * for a chip that has the controller
 */
#if CONFIG_LUAOS_USB_HOST

#include <usb/usb_host.h>

#define USB_TASK_STACK 4096

static usb_host_client_handle_t client;

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

	if (usb_host_get_device_descriptor(dev, &dd) == ESP_OK)
		sayf("usb: %u vid %04x pid %04x class %02x/%02x usb %04x",
		    addr, dd->idVendor, dd->idProduct, dd->bDeviceClass,
		    dd->bDeviceSubClass, dd->bcdUSB);

	if (usb_host_get_active_config_descriptor(dev, &cfg) == ESP_OK) {
		sayf("usb: %u config %u interfaces, %u bytes",
		    addr, cfg->bNumInterfaces, cfg->wTotalLength);
		dumpcfg(cfg);
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
		break;
	default:
		break;
	}
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

void
esp_usb_start(void)
{
	xTaskCreate(usbtask, "usb", USB_TASK_STACK, NULL, 5, NULL);
}

#else

void
esp_usb_start(void)
{
}

#endif
