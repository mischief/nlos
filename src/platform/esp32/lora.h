#ifndef LUAOS_LORA_H
#define LUAOS_LORA_H

#include <stdint.h>

/* the radio answers on the shared spi bus. present() probes once and
 * says what it found; xfer carries one command, opcode included, and
 * waits out BUSY on the way in.
 */
int	esp_lora_present(void);
int	esp_lora_xfer(const uint8_t *tx, uint8_t *rx, int n);

#endif
