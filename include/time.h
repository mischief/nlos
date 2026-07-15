#ifndef _TIME_H
#define _TIME_H

typedef long long time_t;
typedef long long clock_t;

#define CLOCKS_PER_SEC	1000000

time_t	time(time_t *t);
clock_t	clock(void);

#endif
