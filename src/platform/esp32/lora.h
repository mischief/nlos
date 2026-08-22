#ifndef LUAOS_LORA_H
#define LUAOS_LORA_H

#include <stdint.h>

/* the radio on the shared spi bus. xfer carries one command, opcode
 * included, and waits out BUSY first; irq() is DIO1, which the chip
 * raises when a packet is done either way.
 */
int	esp_lora_present(void);
int	esp_lora_xfer(const uint8_t *tx, uint8_t *rx, int n);
int	esp_lora_reset(void);
int	esp_lora_irq(void);

#endif
