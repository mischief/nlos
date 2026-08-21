/* I2S audio out: the amplifier wired to the board, not a device on a
 * bus. There is nothing to enumerate and nothing to claim -- a rate and
 * a channel count is the whole negotiation -- so this is much less than
 * usb.c beside it, and the DMA ring is what absorbs a late writer.
 */

#include <stdint.h>
#include <string.h>

#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "esp32.h"
#include "platform.h"

#if CONFIG_LUAOS_I2S_AUDIO

#include <driver/i2s_std.h>

static i2s_chan_handle_t tx;
static int rate_now;
static int chans_now;
static unsigned long late;
static int filling;	/* loading the buffers before the clock starts */

/* how much the DMA holds, and so how late a writer may be before the
 * amplifier runs dry. A descriptor carries at most 4092 bytes and its
 * size must be a whole number of cache lines, so at four bytes a frame
 * and 64 bytes a line the most that fits is 1008. Eight of those is
 * 168ms at 48kHz, out of the internal memory they must come from.
 */
#define DMA_FRAMES 1008
#define DMA_COUNT 8

int
platform_i2s_have(void)
{
	return 1;
}

void
platform_i2s_stop(void)
{
	if (!tx)
		return;
	if (!filling)
		i2s_channel_disable(tx);
	filling = 0;
	i2s_del_channel(tx);
	tx = NULL;
	rate_now = 0;
	chans_now = 0;
}

/* open at a rate and a width. 16 bit is the only width offered: it is
 * what every wav this machine plays decodes to, and the amplifier takes
 * whatever the clock divider can reach.
 */
int
platform_i2s_play(int rate, int channels)
{
	i2s_chan_config_t cc = I2S_CHANNEL_DEFAULT_CONFIG(I2S_NUM_0,
	    I2S_ROLE_MASTER);

	if (rate <= 0 || channels < 1 || channels > 2)
		return -1;

	platform_i2s_stop();

	cc.dma_desc_num = DMA_COUNT;
	cc.dma_frame_num = DMA_FRAMES;
	cc.auto_clear = true;

	if (i2s_new_channel(&cc, &tx, NULL) != ESP_OK) {
		tx = NULL;
		return -1;
	}

	i2s_std_config_t sc = {
		.clk_cfg = I2S_STD_CLK_DEFAULT_CONFIG((uint32_t)rate),
		.slot_cfg = I2S_STD_PHILIPS_SLOT_DEFAULT_CONFIG(
		    I2S_DATA_BIT_WIDTH_16BIT,
		    channels == 1 ? I2S_SLOT_MODE_MONO : I2S_SLOT_MODE_STEREO),
		.gpio_cfg = {
			.mclk = I2S_GPIO_UNUSED,
			.bclk = TDECK_I2S_BCK,
			.ws = TDECK_I2S_WS,
			.dout = TDECK_I2S_DOUT,
			.din = I2S_GPIO_UNUSED,
			.invert_flags = {
				.mclk_inv = false,
				.bclk_inv = false,
				.ws_inv = false,
			},
		},
	};

	if (i2s_channel_init_std_mode(tx, &sc) != ESP_OK) {
		i2s_del_channel(tx);
		tx = NULL;
		return -1;
	}

	/* not enabled yet: the buffers are loaded first, so the clock
	 * starts against a full ring rather than an empty one. A reader
	 * that has to stay ahead from the first frame has no slack.
	 */
	rate_now = rate;
	chans_now = channels;
	late = 0;
	filling = 1;
	return 0;
}

/* what was taken. A short answer is the DMA being full, which is the
 * one thing a caller reacts to: it is the pace, and outrunning it is
 * how the audio arrives late.
 */
int
platform_i2s_write(const void *p, int n)
{
	size_t wrote = 0;

	if (!tx || n <= 0)
		return -1;

	/* fill before starting. preload answers short once the buffers are
	 * full, and that is the moment to start the clock.
	 */
	if (filling) {
		if (i2s_channel_preload_data(tx, p, (size_t)n, &wrote) !=
		    ESP_OK)
			return -1;
		if (wrote < (size_t)n) {
			filling = 0;
			if (i2s_channel_enable(tx) != ESP_OK)
				return -1;
		}
		return (int)wrote;
	}

	/* long enough that the DMA draining is what paces the caller: a
	 * short timeout hands back a partial write and the caller spins
	 * on a sleep of its own, which is worse timing than the hardware's
	 */
	if (i2s_channel_write(tx, p, (size_t)n, &wrote,
	    pdMS_TO_TICKS(200)) != ESP_OK && wrote == 0)
		late++;
	return (int)wrote;
}

unsigned long
platform_i2s_underruns(void)
{
	return late;
}

#else

int
platform_i2s_have(void)
{
	return 0;
}

int
platform_i2s_play(int rate, int channels)
{
	(void)rate;
	(void)channels;
	return -1;
}

int
platform_i2s_write(const void *p, int n)
{
	(void)p;
	(void)n;
	return -1;
}

void
platform_i2s_stop(void)
{
}

unsigned long
platform_i2s_underruns(void)
{
	return 0;
}

#endif
