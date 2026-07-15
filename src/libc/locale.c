#include <locale.h>
#include <stddef.h>

/* C locale forever */

static struct lconv c_locale = {
	.decimal_point = ".",
	.thousands_sep = "",
	.grouping = "",
};

struct lconv *
localeconv(void)
{
	return &c_locale;
}

char *
setlocale(int category, const char *locale)
{
	(void)category;
	(void)locale;
	return "C";
}
