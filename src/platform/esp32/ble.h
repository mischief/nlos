/* the BLE controller, as HCI packets in and out. */

#ifndef LUAOS_ESP32_BLE_H
#define LUAOS_ESP32_BLE_H

#include <stddef.h>
#include <stdint.h>

/* the largest HCI packet either direction, with its H4 type byte. An
 * event is 2 bytes of header and at most 255 of parameters; an ACL
 * packet is 4 and, with data length extension, 251. The room above
 * both is deliberate: a buffer that exactly fits the largest legal
 * packet leaves nothing for a controller that counts differently.
 */
#define ESP_BLE_MAXPKT 512

/* start the controller in BLE mode and register for its packets. Safe
 * to call twice. 0 on success.
 */
int esp_ble_bringup(void);

/* whether the controller is up. */
int esp_ble_present(void);

/* the next packet the controller sent, or 0 when none is waiting.
 * Includes the H4 type byte, so the caller sees what a uart would.
 */
size_t esp_ble_recv_packet(void *buf, size_t max);

/* one packet to the controller, H4 type byte included. 0 on success,
 * -1 when it is not ready or the packet is impossible.
 */
int esp_ble_send_packet(const void *buf, size_t len);

/* packets taken from the controller, and packets it offered that no
 * slot was free for.
 */
unsigned long esp_ble_irqs(void);
unsigned long esp_ble_drops(void);

/* internal SRAM the controller took, measured across bringup. PSRAM is
 * plentiful here and internal memory is not, so this is the number that
 * decides whether BLE fits beside the radio.
 */
unsigned long esp_ble_sram_cost(void);

#endif
