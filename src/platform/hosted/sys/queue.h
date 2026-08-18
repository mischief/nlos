/* the project's queue.h rather than the host's: TAILQ_FOREACH_SAFE is a
 * BSD extension that glibc's copy does not carry, and src/cpu.h needs
 * it. The platform include directory is searched before the system
 * ones, so this is what <sys/queue.h> finds here.
 */
#include "../../../../include/sys/queue.h"
