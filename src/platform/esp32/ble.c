/* the BLE controller: HCI packets in and out, nothing above them.
 * Not NimBLE, for the reason wifi.c is not esp_netif -- a host stack in
 * the image is what lib/ble exists instead of. Packets carry the H4
 * type byte a uart transport would, so lib/ble reads the same bytes
 * here as against a socket on the host.
 */

#include <string.h>

#include <esp_bt.h>
#include <esp_err.h>
#include <esp_heap_caps.h>
#include <esp_log.h>
#include <freertos/FreeRTOS.h>

#include "platform.h"
#include "ble.h"

/* Packets arrive on the controller's task and leave on the kernel's, so
 * the ring is the one place here with two threads in it. A spinlock and
 * a copy, as wifi.c does: the producer must return promptly, and the
 * controller reuses its buffer the moment it does.
 */
#define NSLOT 24

struct slot {
	uint16_t len;
	uint8_t buf[ESP_BLE_MAXPKT];
};

static struct slot *ring;
static unsigned rhead, rtail;
static portMUX_TYPE ringlock = portMUX_INITIALIZER_UNLOCKED;

static unsigned long irqs, drops;
static unsigned long sramcost;
static int up;

/* the controller's task calls this, with a packet it owns. */
static int
hcirecv(uint8_t *data, uint16_t len)
{
	unsigned next;

	if (len > ESP_BLE_MAXPKT)
		len = ESP_BLE_MAXPKT;

	portENTER_CRITICAL(&ringlock);
	next = (rhead + 1) % NSLOT;
	if (next == rtail) {
		drops++;
	} else {
		memcpy(ring[rhead].buf, data, len);
		ring[rhead].len = len;
		rhead = next;
		irqs++;
	}
	portEXIT_CRITICAL(&ringlock);
	return 0;
}

/* the controller has room again. Nothing waits on this: the send path
 * asks before each packet, which is what the API requires anyway.
 */
static void
hcisendable(void)
{
}

static const esp_vhci_host_callback_t vhci_cb = {
	.notify_host_send_available = hcisendable,
	.notify_host_recv = hcirecv,
};

int
esp_ble_bringup(void)
{
	esp_bt_controller_config_t cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
	unsigned before;

	if (up)
		return 0;

	if (ring == NULL) {
		/* PSRAM: nothing here is handed to DMA, both sides copy,
		 * so the slower memory costs a memcpy and no correctness.
		 */
		ring = heap_caps_malloc(sizeof(*ring) * NSLOT,
		    MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
		if (ring == NULL)
			ring = heap_caps_malloc(sizeof(*ring) * NSLOT,
			    MALLOC_CAP_8BIT);
		if (ring == NULL)
			return -1;
	}

	esp_log_level_set("BT_INIT", ESP_LOG_ERROR);

	before = (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL);

	if (esp_bt_controller_init(&cfg) != ESP_OK)
		return -1;
	if (esp_bt_controller_enable(ESP_BT_MODE_BLE) != ESP_OK) {
		esp_bt_controller_deinit();
		return -1;
	}
	if (esp_vhci_host_register_callback(&vhci_cb) != ESP_OK) {
		esp_bt_controller_disable();
		esp_bt_controller_deinit();
		return -1;
	}

	sramcost = before - (unsigned)heap_caps_get_free_size(
	    MALLOC_CAP_INTERNAL);
	up = 1;
	return 0;
}

int
esp_ble_present(void)
{
	return up;
}

size_t
esp_ble_recv_packet(void *buf, size_t max)
{
	size_t n = 0;

	if (ring == NULL)
		return 0;

	portENTER_CRITICAL(&ringlock);
	if (rtail != rhead) {
		n = ring[rtail].len;
		if (n > max)
			n = max;
		memcpy(buf, ring[rtail].buf, n);
		rtail = (rtail + 1) % NSLOT;
	}
	portEXIT_CRITICAL(&ringlock);
	return n;
}

int
esp_ble_send_packet(const void *buf, size_t len)
{
	if (!up || len == 0 || len > ESP_BLE_MAXPKT)
		return -1;
	/* the controller is entitled to refuse, and a caller that sends
	 * anyway corrupts its transport rather than being told no.
	 */
	if (!esp_vhci_host_check_send_available())
		return -1;
	/* takes a non-const pointer and copies before it returns, so a
	 * lua string does not have to outlive the call.
	 */
	esp_vhci_host_send_packet((uint8_t *)buf, (uint16_t)len);
	return 0;
}

unsigned long
esp_ble_irqs(void)
{
	return irqs;
}

unsigned long
esp_ble_drops(void)
{
	return drops;
}

unsigned long
esp_ble_sram_cost(void)
{
	return sramcost;
}
