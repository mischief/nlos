/* the wifi radio: 802.3 frames in and out, and the association beside.
 *
 * Deliberately not esp_netif, which is the arrangement every esp32
 * project uses: esp_netif binds the radio to lwip and hands back a
 * socket API, and a second IP stack in the image is exactly what this
 * one exists instead of. esp_wifi_internal_reg_rxcb and
 * esp_wifi_internal_tx are the layer esp_netif itself sits on -- plain
 * ethernet frames, no addressing, no protocol -- so lib/ip4.lua and
 * everything above it runs here as it does over virtio-net.
 *
 * The cost of that choice is the two functions being private headers:
 * esp_private/wifi.h is not the documented API and has moved once
 * already, from esp_wifi_internal.h. What holds it in place is that
 * esp_netif has no other way in either, so the pair cannot leave while
 * IDF still has a network stack.
 *
 * NVS has to exist before the radio starts. The driver keeps its
 * calibration there, and esp_wifi_init fails without it.
 */

#include <string.h>

#include <esp_err.h>
#include <esp_event.h>
#include <esp_heap_caps.h>
#include <esp_log.h>
#include <esp_mac.h>
#include <esp_wifi.h>
#include <esp_private/wifi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <nvs_flash.h>

#include "platform.h"
#include "wifi.h"

enum { WIFI_IDLE, WIFI_JOINING, WIFI_JOINED, WIFI_FAILED };

/* Frames arrive on the wifi task and leave on the kernel's, so the ring
 * is the one place here with two threads in it. A spinlock rather than
 * a queue: the producer copies and returns, and holding it across a
 * memcpy of at most 1514 bytes is shorter than the queue send it would
 * replace.
 *
 * 16 slots is 24KB, in PSRAM. A burst deeper than that means the
 * consumer is not running, and the frame is dropped -- which is what an
 * ethernet does under the same conditions, and is why drops are counted
 * rather than the driver blocking the radio.
 */
#define NSLOT 16

struct slot {
	uint16_t len;
	uint8_t buf[ESP_WIFI_MAXFRAME];
};

static struct slot *ring;
static unsigned rhead, rtail;
static portMUX_TYPE ringlock = portMUX_INITIALIZER_UNLOCKED;

static unsigned long irqs, drops;

static int up;
static int state;
static int lastreason;
static char lastssid[33];
/* set from the driver's event task, read from the kernel's: one flag
 * written on one side and cleared on the other, so no lock.
 */
static volatile int scandone;
static int scanning;

/* the radio's own task calls this. Copy and return: the buffer belongs
 * to the driver, and holding it would starve the receive path.
 */
static esp_err_t
rxframe(void *buffer, uint16_t len, void *eb)
{
	unsigned next;

	if (len > ESP_WIFI_MAXFRAME)
		len = ESP_WIFI_MAXFRAME;

	portENTER_CRITICAL(&ringlock);
	next = (rhead + 1) % NSLOT;
	if (next == rtail) {
		drops++;
		portEXIT_CRITICAL(&ringlock);
	} else {
		memcpy(ring[rhead].buf, buffer, len);
		ring[rhead].len = len;
		rhead = next;
		irqs++;
		portEXIT_CRITICAL(&ringlock);
	}
	if (eb)
		esp_wifi_internal_free_rx_buffer(eb);
	return ESP_OK;
}

/* Association is asynchronous and this is where it lands.
 *
 * A disconnect is not retried here. The kernel above decides what to do
 * about a network that went away, and a driver quietly reconnecting
 * would hide from it that anything had happened.
 */
static void
onwifi(void *arg, esp_event_base_t base, int32_t id, void *data)
{
	(void)arg;
	(void)base;

	switch (id) {
	case WIFI_EVENT_STA_CONNECTED:
		state = WIFI_JOINED;
		/* the receive path is registered once associated: before
		 * that there is no interface to register it on.
		 */
		esp_wifi_internal_reg_rxcb(WIFI_IF_STA, rxframe);
		break;
	case WIFI_EVENT_SCAN_DONE:
		scandone = 1;
		break;
	case WIFI_EVENT_STA_DISCONNECTED: {
		wifi_event_sta_disconnected_t *d = data;

		lastreason = d ? d->reason : 0;
		state = (state == WIFI_JOINING) ? WIFI_FAILED : WIFI_IDLE;
		esp_wifi_internal_reg_rxcb(WIFI_IF_STA, NULL);
		break;
	}
	}
}

int
esp_wifi_bringup(void)
{
	wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
	esp_err_t e;

	if (up)
		return 0;

	if (ring == NULL) {
		/* PSRAM: 24KB is a tenth of the internal heap and the
		 * radio needs what is left of it. Nothing here is handed
		 * to DMA -- both halves copy -- so the slower memory
		 * costs a memcpy and no correctness.
		 */
		ring = heap_caps_malloc(sizeof(*ring) * NSLOT,
		    MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
		if (ring == NULL)
			ring = heap_caps_malloc(sizeof(*ring) * NSLOT,
			    MALLOC_CAP_8BIT);
		if (ring == NULL)
			return -1;
	}

	e = nvs_flash_init();
	if (e == ESP_ERR_NVS_NO_FREE_PAGES ||
	    e == ESP_ERR_NVS_NEW_VERSION_FOUND) {
		/* the partition table changed under it, which is what a
		 * reflash with a new layout looks like from here.
		 */
		nvs_flash_erase();
		e = nvs_flash_init();
	}
	if (e != ESP_OK)
		return -1;

	/* The radio's own tag, silenced to errors.
	 *
	 * The C5 driver dumps its calibration at warning level -- twenty
	 * lines of register values and delay constants every time the
	 * radio starts -- so turning the global level down to warnings is
	 * not enough to keep the console readable. A per-tag level leaves
	 * every other component's warnings where they are.
	 *
	 * Runtime rather than a config: the strings are compiled in at
	 * warning level and this lowers what is printed, which is the only
	 * way to treat one component differently from the rest.
	 */
	esp_log_level_set("wifi", ESP_LOG_ERROR);

	if (esp_event_loop_create_default() != ESP_OK)
		return -1;
	if (esp_wifi_init(&cfg) != ESP_OK)
		return -1;
	if (esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
	    onwifi, NULL, NULL) != ESP_OK)
		return -1;
	/* the credentials live in a file on luafs, not in the driver's
	 * own NVS copy: one place for them, and one that can be read and
	 * edited from the machine.
	 */
	if (esp_wifi_set_storage(WIFI_STORAGE_RAM) != ESP_OK)
		return -1;
	if (esp_wifi_set_mode(WIFI_MODE_STA) != ESP_OK)
		return -1;
	if (esp_wifi_start() != ESP_OK)
		return -1;

	/* The radio sleeps between beacons by default and wakes on the
	 * AP's DTIM, which puts most of a beacon interval in front of
	 * anything arriving for us. Measured over 25 pings on a 102400us
	 * interval: 208/304/577ms min/avg/max asleep, against 25/44/163
	 * awake.
	 *
	 * Awake, because this machine is a terminal: the latency is paid
	 * by every keystroke over ssh and every 9p round trip, and a
	 * board being used is a board on its cable. Somewhere to revisit
	 * if it ever runs on its battery.
	 *
	 * What is left is not the beacon. A 25ms floor with 28ms of
	 * deviation is this machine's own path -- the frame crosses eth,
	 * ip and back through a cooperative scheduler -- plus whatever
	 * the air retries.
	 */
	if (esp_wifi_set_ps(WIFI_PS_NONE) != ESP_OK)
		return -1;

	up = 1;
	return 0;
}

int
esp_wifi_present(void)
{
	return up;
}

int
esp_wifi_connect_to(const char *ssid, const char *psk)
{
	wifi_config_t cfg;

	if (!up && esp_wifi_bringup() != 0)
		return -1;
	if (ssid == NULL || *ssid == 0)
		return -1;

	memset(&cfg, 0, sizeof cfg);
	strncpy((char *)cfg.sta.ssid, ssid, sizeof cfg.sta.ssid - 1);
	if (psk != NULL && *psk != 0)
		strncpy((char *)cfg.sta.password, psk,
		    sizeof cfg.sta.password - 1);

	/* One name may be several access points. Scanning every channel
	 * and sorting by signal associates to the nearest of them rather
	 * than the first heard; the retry count is what moves on to the
	 * next when the nearest will not take us. Which NETWORK to join
	 * is decided above this, from a list this layer never sees.
	 */
	cfg.sta.scan_method = WIFI_ALL_CHANNEL_SCAN;
	cfg.sta.sort_method = WIFI_CONNECT_AP_BY_SIGNAL;
	cfg.sta.failure_retry_cnt = 2;

	strncpy(lastssid, ssid, sizeof lastssid - 1);
	lastssid[sizeof lastssid - 1] = 0;

	if (esp_wifi_set_config(WIFI_IF_STA, &cfg) != ESP_OK)
		return -1;

	/* a fresh attempt, so an earlier failure stops being reported */
	lastreason = 0;
	state = WIFI_JOINING;
	if (esp_wifi_connect() != ESP_OK) {
		state = WIFI_FAILED;
		return -1;
	}
	return 0;
}

int
esp_wifi_scan_begin(void)
{
	wifi_scan_config_t cfg;

	if (!up && esp_wifi_bringup() != 0)
		return -1;
	if (scanning)
		return 0;	/* one is already running; take collects it */

	memset(&cfg, 0, sizeof cfg);
	cfg.show_hidden = false;
	/* active, and the driver's own dwell: a hidden network needs a
	 * probe anyway, and the defaults are tuned for this radio.
	 */
	cfg.scan_type = WIFI_SCAN_TYPE_ACTIVE;

	scandone = 0;
	if (esp_wifi_scan_start(&cfg, false) != ESP_OK)
		return -1;
	scanning = 1;
	return 0;
}

int
esp_wifi_scan_take(struct esp_wifi_ap *out, int max)
{
	uint16_t n;
	wifi_ap_record_t *recs;
	int got = 0;

	if (!scanning || !scandone)
		return -1;

	/* cleared before the records are read, not after: a failure below
	 * still ends this scan, or begin would refuse to start another.
	 */
	scanning = 0;
	scandone = 0;

	if (esp_wifi_scan_get_ap_num(&n) != ESP_OK || n == 0)
		return 0;
	if (n > max)
		n = max;

	recs = calloc(n, sizeof *recs);
	if (recs == NULL) {
		/* the driver holds the list until it is read; drop it so
		 * the memory is not pinned until the next scan.
		 */
		esp_wifi_clear_ap_list();
		return 0;
	}
	if (esp_wifi_scan_get_ap_records(&n, recs) == ESP_OK) {
		for (int i = 0; i < n; i++) {
			snprintf(out[got].ssid, sizeof out[got].ssid, "%s",
			    (const char *)recs[i].ssid);
			out[got].rssi = recs[i].rssi;
			out[got].open =
			    recs[i].authmode == WIFI_AUTH_OPEN;
			out[got].channel = recs[i].primary;
			got++;
		}
	}
	free(recs);
	return got;
}

int
esp_wifi_disconnect_from(void)
{
	if (!up)
		return -1;
	state = WIFI_IDLE;
	return esp_wifi_disconnect() == ESP_OK ? 0 : -1;
}

int
esp_wifi_state(int *reason, const char **ssid)
{
	if (reason != NULL)
		*reason = lastreason;
	if (ssid != NULL)
		*ssid = lastssid[0] ? lastssid : NULL;
	return state;
}

int
esp_wifi_mac(uint8_t mac[6])
{
	if (!up)
		return -1;
	return esp_wifi_get_mac(WIFI_IF_STA, mac) == ESP_OK ? 0 : -1;
}

size_t
esp_wifi_recv_frame(void *buf, size_t max)
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
esp_wifi_send_frame(const void *buf, size_t len)
{
	if (state != WIFI_JOINED)
		return -1;
	if (len == 0 || len > ESP_WIFI_MAXFRAME)
		return -1;
	/* esp_wifi_internal_tx copies before it returns, so the caller's
	 * buffer -- a lua string -- does not have to outlive the call.
	 */
	return esp_wifi_internal_tx(WIFI_IF_STA, (void *)buf,
	    (uint16_t)len) == ESP_OK ? 0 : -1;
}

unsigned long
esp_wifi_irqs(void)
{
	return irqs;
}

unsigned long
esp_wifi_drops(void)
{
	return drops;
}
