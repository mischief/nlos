/* the radio, as a network interface and a thing to associate.
 *
 * Two halves that have nothing to do with each other. Frames are the
 * same surface a virtio-net or an SNP gives -- mac, send, recv, a count
 * of arrivals -- so task/eth.lua and everything above it works here
 * unchanged. Association is a control plane beside that, and is what
 * ssid and psk belong to.
 *
 * Keeping them apart is what lets the interface exist before it is
 * associated: the NIC is present from boot, and an unassociated radio
 * is an unplugged cable rather than a missing device.
 */
#ifndef ESP32_WIFI_H
#define ESP32_WIFI_H

#include <stdint.h>
#include <stddef.h>

/* the largest 802.3 frame the driver hands up, and the size of one ring
 * slot. 1514 is the ethernet maximum without the FCS, which esp_wifi
 * has already checked and stripped.
 */
#define ESP_WIFI_MAXFRAME 1514

/* bring the radio up in station mode. Idempotent, and does not
 * associate: that is esp_wifi_connect_to. 0 on success.
 */
int esp_wifi_bringup(void);

/* is the radio up? The interface exists from then on, associated or
 * not.
 */
int esp_wifi_present(void);

/* associate. psk may be NULL or empty for an open network. Returns 0
 * once the attempt has started -- association is asynchronous, and
 * esp_wifi_state is what says whether it worked.
 */
int esp_wifi_connect_to(const char *ssid, const char *psk);

int esp_wifi_disconnect_from(void);

/* 0 idle, 1 associating, 2 associated, 3 failed. reason is the driver's
 * disconnect reason on 3, and ssid the network named in the last
 * attempt; either may be NULL.
 */
int esp_wifi_state(int *reason, const char **ssid);

/* our mac, six bytes. 0 on success. */
int esp_wifi_mac(uint8_t mac[6]);

/* one frame, or 0 if the ring is empty. Copies into buf, which must
 * hold ESP_WIFI_MAXFRAME.
 */
size_t esp_wifi_recv_frame(void *buf, size_t max);

/* send one 802.3 frame. 0 on success. */
int esp_wifi_send_frame(const void *buf, size_t len);

/* frames accepted into the ring since boot, which is what the scheduler
 * watches to know the device has done something.
 */
unsigned long esp_wifi_irqs(void);

/* frames dropped because the ring was full: the consumer is not
 * keeping up, and unlike a lost keystroke this is worth reporting.
 */
unsigned long esp_wifi_drops(void);

#endif
