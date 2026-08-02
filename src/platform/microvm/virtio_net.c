/* virtio-net: two queues, raw frames, no protocol.
 *
 * Queue 0 receives and queue 1 transmits -- that assignment is the
 * specification's, not a choice. Receive buffers are posted at init and
 * re-posted as they complete, so the device always has somewhere to put
 * a frame that arrives while nothing is asking for one.
 */

#include <stdint.h>
#include <string.h>

#include "microvm.h"
#include "virtio.h"
#include "virtio_net.h"

#define VIRTIO_ID_NET 1
#define CONFIG_OFF    0x100

#define VIRTQ_RX 0
#define VIRTQ_TX 1

/* the only feature asked for. Everything else the device offers --
 * checksum offload, segmentation, and above all MRG_RXBUF -- is
 * declined on purpose: accepting MRG_RXBUF changes the header to 12
 * bytes and lets one frame span several buffers, which is a real
 * receive path rather than this one.
 */
#define VIRTIO_NET_F_MAC (1u << 5)

/* prepended to every frame in both directions. 10 bytes exactly,
 * because MRG_RXBUF was declined above; do not reorder or pad.
 */
struct virtio_net_hdr {
	uint8_t flags;
	uint8_t gso_type;
	uint16_t hdr_len;
	uint16_t gso_size;
	uint16_t csum_start;
	uint16_t csum_offset;
};

#define NET_HDR_LEN 10

/* 1514 is ethernet's payload-carrying maximum without tags; the header
 * rides in the same buffer, and the whole thing is rounded up so a
 * buffer never straddles more of a page than it needs to.
 */
#define FRAME_MAX 1514
#define BUF_SIZE  2048

#define NRX 16
#define NTX 8

static struct virtio_dev netdev;
static int net_ready;
static unsigned char net_mac[6];
static int have_mac;

/* descriptor index -> the buffer posted with it. Both queues allocate
 * their descriptors at init and keep them, so these stay valid for the
 * life of the machine.
 */
static char *rxbuf[NRX];
static uint16_t rxdesc[NRX];
static char *txbuf[NTX];
static uint16_t txdesc[NTX];
static int txfree[NTX];		/* 1 = available to send with */

_Static_assert(sizeof(struct virtio_net_hdr) == NET_HDR_LEN,
    "virtio_net_hdr must be exactly 10 bytes with MRG_RXBUF declined");

/* hand a receive descriptor back to the device. Called at init for
 * every buffer, and again each time one completes -- a receive queue
 * that is not kept full silently drops frames.
 */
static void
rx_post(int i)
{
	virtio_desc_set(&netdev, VIRTQ_RX, rxdesc[i], rxbuf[i], BUF_SIZE, 1, -1);
	virtio_submit(&netdev, VIRTQ_RX, rxdesc[i]);
}

int
virtio_net_init(void)
{
	uint64_t got = 0;

	if (virtio_find(VIRTIO_ID_NET, &netdev) != 0)
		return -1;
	if (virtio_dev_begin(&netdev, VIRTIO_NET_F_MAC, &got) != 0)
		return -1;
	if (virtio_queue_init(&netdev, VIRTQ_RX, NRX) != 0)
		return -1;
	if (virtio_queue_init(&netdev, VIRTQ_TX, NTX) != 0)
		return -1;

	char *mem = pmm_alloc((size_t)(NRX + NTX) * BUF_SIZE);

	if (!mem)
		return -1;

	for (int i = 0; i < NRX; i++) {
		int d = virtio_desc_alloc(&netdev, VIRTQ_RX);

		if (d < 0)
			return -1;
		rxbuf[i] = mem + (size_t)i * BUF_SIZE;
		rxdesc[i] = (uint16_t)d;
	}
	for (int i = 0; i < NTX; i++) {
		int d = virtio_desc_alloc(&netdev, VIRTQ_TX);

		if (d < 0)
			return -1;
		txbuf[i] = mem + (size_t)(NRX + i) * BUF_SIZE;
		txdesc[i] = (uint16_t)d;
		txfree[i] = 1;
	}

	if (got & VIRTIO_NET_F_MAC) {
		for (int i = 0; i < 6; i++)
			net_mac[i] = virtio_config8(&netdev, i);
		have_mac = 1;
	}

	/* buffers must be posted before DRIVER_OK, or the device may take
	 * the first frame off the wire with nowhere to put it.
	 */
	virtio_dev_ready(&netdev);
	for (int i = 0; i < NRX; i++)
		rx_post(i);

	/* frames arrive unasked, so this is the device that most wants a
	 * line: without one an idle machine has to keep asking.
	 */
	virtio_irq_enable(&netdev);

	net_ready = 1;
	return 0;
}

int
virtio_net_mac(unsigned char out[6])
{
	if (!net_ready || !have_mac)
		return -1;
	memcpy(out, net_mac, 6);
	return 0;
}

/* take back any transmit buffers the device has finished with. */
static void
tx_reap(void)
{
	uint16_t id;
	uint32_t len;

	while (virtio_poll_used(&netdev, VIRTQ_TX, &id, &len)) {
		for (int i = 0; i < NTX; i++) {
			if (txdesc[i] == id) {
				txfree[i] = 1;
				break;
			}
		}
	}
}

int
virtio_net_send(const void *frame, size_t n)
{
	if (!net_ready || n > FRAME_MAX)
		return -1;

	tx_reap();

	int i;

	for (i = 0; i < NTX; i++) {
		if (txfree[i])
			break;
	}
	if (i == NTX)
		return -1;		/* every buffer still in flight */

	struct virtio_net_hdr *h = (struct virtio_net_hdr *)txbuf[i];

	memset(h, 0, NET_HDR_LEN);
	memcpy(txbuf[i] + NET_HDR_LEN, frame, n);

	txfree[i] = 0;
	virtio_desc_set(&netdev, VIRTQ_TX, txdesc[i], txbuf[i],
	    (uint32_t)(NET_HDR_LEN + n), 0, -1);
	virtio_submit(&netdev, VIRTQ_TX, txdesc[i]);
	return 0;
}

int
virtio_net_recv(void *buf, size_t cap)
{
	uint16_t id;
	uint32_t len;

	if (!net_ready)
		return 0;
	if (!virtio_poll_used(&netdev, VIRTQ_RX, &id, &len))
		return 0;

	int i;

	for (i = 0; i < NRX; i++) {
		if (rxdesc[i] == id)
			break;
	}
	if (i == NRX)
		return 0;		/* not one of ours; ignore it */

	int rc = 0;

	/* len counts the header the device prepended */
	if (len > NET_HDR_LEN) {
		size_t n = len - NET_HDR_LEN;

		if (n > cap) {
			rc = -1;
		} else {
			memcpy(buf, rxbuf[i] + NET_HDR_LEN, n);
			rc = (int)n;
		}
	}

	/* re-post before returning, whatever happened above: a buffer kept
	 * back is one the device can never use again.
	 */
	rx_post(i);
	return rc;
}
