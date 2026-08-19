#ifndef KSTAT_H
#define KSTAT_H

#include <stdatomic.h>

/* a counter with one writer -- a lock's holder, or the cpu a proc, a cpu
 * record or a heap belongs to -- and readers elsewhere building a
 * report. Atomic for those readers, never read-modify-written, so the
 * writer pays a relaxed load and store: plain instructions.
 */
#define KSTAT_GET(f)		atomic_load_explicit(&(f), memory_order_relaxed)
#define KSTAT_SET(f, v)		atomic_store_explicit(&(f), (v), memory_order_relaxed)
#define KSTAT_ADD(f, n)		KSTAT_SET(f, KSTAT_GET(f) + (n))

#endif
