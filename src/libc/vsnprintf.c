/* small vsnprintf. supports:
 *   %d %i %u %o %x %X %c %s %p %% %f %e %E %g %G
 *   flags - + 0 space #, width, .precision, * for both,
 *   length h hh l ll z t
 * float conversion is digit-loop based, accurate to ~16 significant
 * digits; enough for lua's %.14g number formatting.
 */

#include <stdio.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
#include <stdbool.h>

struct out {
	char *buf;
	size_t cap;	/* bytes usable for chars (cap-1) + nul */
	size_t pos;	/* would-be length */
};

static void
outc(struct out *o, char c)
{
	if (o->pos + 1 < o->cap)
		o->buf[o->pos] = c;
	o->pos++;
}

static void
outn(struct out *o, const char *s, size_t n)
{
	while (n--)
		outc(o, *s++);
}

static void
pad(struct out *o, char c, int n)
{
	while (n-- > 0)
		outc(o, c);
}

/* flags */
#define F_LEFT	0x01
#define F_PLUS	0x02
#define F_SPACE	0x04
#define F_ZERO	0x08
#define F_ALT	0x10

static void
emit_num(struct out *o, const char *digits, int ndig, char sign,
    const char *prefix, int prec, int width, int flags)
{
	int len, zeros = 0;

	if (prec > ndig)
		zeros = prec - ndig;
	len = ndig + zeros + (sign ? 1 : 0) + strlen(prefix);

	if (!(flags & F_LEFT)) {
		if ((flags & F_ZERO) && prec < 0)
			zeros += width - len > 0 ? width - len : 0;
		else
			pad(o, ' ', width - len);
	}
	if (sign)
		outc(o, sign);
	outn(o, prefix, strlen(prefix));
	pad(o, '0', zeros);
	outn(o, digits, ndig);
	if (flags & F_LEFT)
		pad(o, ' ', width - (len > width ? len : len +
		    (zeros - (prec > ndig ? prec - ndig : 0))));
}

static int
fmt_int(struct out *o, unsigned long long v, bool neg, int base, bool upper,
    int prec, int width, int flags)
{
	char tmp[24];
	const char *hex = upper ? "0123456789ABCDEF" : "0123456789abcdef";
	char sign = 0;
	const char *prefix = "";
	int n = 0;

	if (v == 0 && prec == 0) {
		/* zero with zero precision prints nothing */
	} else {
		do {
			tmp[n++] = hex[v % base];
			v /= base;
		} while (v);
	}
	for (int i = 0; i < n / 2; i++) {
		char t = tmp[i];

		tmp[i] = tmp[n - 1 - i];
		tmp[n - 1 - i] = t;
	}
	if (neg)
		sign = '-';
	else if (flags & F_PLUS)
		sign = '+';
	else if (flags & F_SPACE)
		sign = ' ';
	if ((flags & F_ALT) && base == 16 && n)
		prefix = upper ? "0X" : "0x";
	else if ((flags & F_ALT) && base == 8 && (n == 0 || tmp[0] != '0'))
		prefix = "0";
	emit_num(o, tmp, n, sign, prefix, prec, width, flags);
	return 0;
}

/* decompose |v| (finite, nonzero) into 17 decimal digits and a
 * base-10 exponent: v ~= 0.d[0]d[1]... * 10^(dexp+1)
 */
static void
decompose(double v, char dig[18], int *dexp)
{
	int e = 0;
	unsigned long long m;

	while (v >= 1e17) {
		v /= 10.0;
		e++;
	}
	while (v < 1e16) {
		v *= 10.0;
		e--;
	}
	m = (unsigned long long)(v + 0.5);
	if (m >= 100000000000000000ULL) {	/* rounding overflowed */
		m /= 10;
		e++;
	}
	for (int i = 16; i >= 0; i--) {
		dig[i] = '0' + m % 10;
		m /= 10;
	}
	dig[17] = 0;
	*dexp = e + 16;	/* exponent of first digit */
}

/* round the digit string to n digits; returns 1 if the leading
 * digit carried (exponent must be bumped)
 */
static int
round_digits(char *dig, int n)
{
	if (n >= 17 || dig[n] < '5')
		return 0;
	for (int i = n - 1; i >= 0; i--) {
		if (dig[i] != '9') {
			dig[i]++;
			for (int j = i + 1; j < n; j++)
				dig[j] = '0';
			return 0;
		}
	}
	dig[0] = '1';
	for (int j = 1; j < n; j++)
		dig[j] = '0';
	return 1;
}

static void
fmt_float(struct out *o, double v, char conv, int prec, int width, int flags)
{
	char dig[18], body[64];
	char sign = 0;
	int dexp, blen = 0;
	bool upper = (conv == 'E' || conv == 'G');
	bool estyle;

	if (conv == 'F')
		conv = 'f';
	if (upper)
		conv = conv + 'a' - 'A';

	if (__builtin_signbit(v))
		sign = '-';
	else if (flags & F_PLUS)
		sign = '+';
	else if (flags & F_SPACE)
		sign = ' ';

	if (__builtin_isnan(v) || __builtin_isinf(v)) {
		const char *s = __builtin_isnan(v) ?
		    (upper ? "NAN" : "nan") : (upper ? "INF" : "inf");
		int len = 3 + (sign ? 1 : 0);

		if (!(flags & F_LEFT))
			pad(o, ' ', width - len);
		if (sign)
			outc(o, sign);
		outn(o, s, 3);
		if (flags & F_LEFT)
			pad(o, ' ', width - len);
		return;
	}

	v = fabs(v);
	if (prec < 0)
		prec = 6;

	if (v == 0.0) {
		memset(dig, '0', 17);
		dig[17] = 0;
		dexp = 0;
	} else
		decompose(v, dig, &dexp);

	if (conv == 'g') {
		int p = prec ? prec : 1;

		if (v != 0.0)
			dexp += round_digits(dig, p);
		if (dexp < -4 || dexp >= p) {
			estyle = true;
			prec = p - 1;
		} else {
			estyle = false;
			prec = p - 1 - dexp;
		}
	} else
		estyle = (conv == 'e');

	if (estyle) {
		int ndig = prec + 1;

		if (ndig > 17)
			ndig = 17;
		if (v != 0.0 && conv != 'g')
			dexp += round_digits(dig, ndig);
		body[blen++] = dig[0];
		if (prec > 0 || (flags & F_ALT)) {
			body[blen++] = '.';
			for (int i = 1; i <= prec && blen < 60; i++)
				body[blen++] = i < 17 ? dig[i] : '0';
		}
		if (conv == 'g' && !(flags & F_ALT)) {
			while (blen > 1 && body[blen - 1] == '0')
				blen--;
			if (blen > 1 && body[blen - 1] == '.')
				blen--;
		}
		body[blen++] = upper ? 'E' : 'e';
		body[blen++] = dexp < 0 ? '-' : '+';
		int ae = dexp < 0 ? -dexp : dexp;

		if (ae >= 100) {
			body[blen++] = '0' + ae / 100;
			ae %= 100;
		}
		body[blen++] = '0' + ae / 10;
		body[blen++] = '0' + ae % 10;
	} else {
		/* f style: digits dig[] start at exponent dexp */
		int last = dexp + prec;	/* index of last printed digit */

		if (v != 0.0 && conv != 'g' && last + 1 >= 0 && last + 1 < 17)
			dexp += round_digits(dig, last + 1);

		if (dexp < 0)
			body[blen++] = '0';
		else
			for (int i = 0; i <= dexp && blen < 40; i++)
				body[blen++] = i < 17 ? dig[i] : '0';
		if (prec > 0 || (flags & F_ALT)) {
			body[blen++] = '.';
			for (int i = dexp + 1; i <= dexp + prec && blen < 60;
			    i++) {
				if (i < 0 || i >= 17)
					body[blen++] = '0';
				else
					body[blen++] = dig[i];
			}
		}
		if (conv == 'g' && !(flags & F_ALT)) {
			if (memchr(body, '.', blen)) {
				while (blen > 1 && body[blen - 1] == '0')
					blen--;
				if (blen > 1 && body[blen - 1] == '.')
					blen--;
			}
		}
	}

	int len = blen + (sign ? 1 : 0);

	if (!(flags & F_LEFT)) {
		if (flags & F_ZERO) {
			if (sign)
				outc(o, sign);
			pad(o, '0', width - len);
			sign = 0;
		} else
			pad(o, ' ', width - len);
	}
	if (sign)
		outc(o, sign);
	outn(o, body, blen);
	if (flags & F_LEFT)
		pad(o, ' ', width - len);
}

int
vsnprintf(char *buf, size_t n, const char *fmt, va_list ap)
{
	struct out o = { buf, n, 0 };

	for (; *fmt; fmt++) {
		int flags = 0, width = 0, prec = -1;
		int lmod = 0;	/* 0=int 1=long 2=llong -1=short -2=char */

		if (*fmt != '%') {
			outc(&o, *fmt);
			continue;
		}
		fmt++;

		for (;; fmt++) {
			if (*fmt == '-')
				flags |= F_LEFT;
			else if (*fmt == '+')
				flags |= F_PLUS;
			else if (*fmt == ' ')
				flags |= F_SPACE;
			else if (*fmt == '0')
				flags |= F_ZERO;
			else if (*fmt == '#')
				flags |= F_ALT;
			else
				break;
		}
		if (*fmt == '*') {
			width = va_arg(ap, int);
			if (width < 0) {
				flags |= F_LEFT;
				width = -width;
			}
			fmt++;
		} else
			for (; *fmt >= '0' && *fmt <= '9'; fmt++)
				width = width * 10 + (*fmt - '0');
		if (*fmt == '.') {
			fmt++;
			prec = 0;
			if (*fmt == '*') {
				prec = va_arg(ap, int);
				fmt++;
			} else
				for (; *fmt >= '0' && *fmt <= '9'; fmt++)
					prec = prec * 10 + (*fmt - '0');
		}
		for (;; fmt++) {
			if (*fmt == 'l')
				lmod++;
			else if (*fmt == 'h')
				lmod--;
			else if (*fmt == 'z' || *fmt == 't')
				lmod = 1;
			else
				break;
		}

		switch (*fmt) {
		case '%':
			outc(&o, '%');
			break;
		case 'c': {
			char c = (char)va_arg(ap, int);

			if (!(flags & F_LEFT))
				pad(&o, ' ', width - 1);
			outc(&o, c);
			if (flags & F_LEFT)
				pad(&o, ' ', width - 1);
			break;
		}
		case 's': {
			const char *s = va_arg(ap, const char *);
			int len;

			if (!s)
				s = "(null)";
			len = strlen(s);
			if (prec >= 0 && len > prec)
				len = prec;
			if (!(flags & F_LEFT))
				pad(&o, ' ', width - len);
			outn(&o, s, len);
			if (flags & F_LEFT)
				pad(&o, ' ', width - len);
			break;
		}
		case 'd':
		case 'i': {
			long long v;

			if (lmod >= 2)
				v = va_arg(ap, long long);
			else if (lmod == 1)
				v = va_arg(ap, long);
			else
				v = va_arg(ap, int);
			fmt_int(&o, v < 0 ? -(unsigned long long)v : (unsigned long long)v,
			    v < 0, 10, false, prec, width, flags);
			break;
		}
		case 'u':
		case 'o':
		case 'x':
		case 'X': {
			unsigned long long v;
			int base = *fmt == 'u' ? 10 : (*fmt == 'o' ? 8 : 16);

			if (lmod >= 2)
				v = va_arg(ap, unsigned long long);
			else if (lmod == 1)
				v = va_arg(ap, unsigned long);
			else
				v = va_arg(ap, unsigned int);
			fmt_int(&o, v, false, base, *fmt == 'X', prec,
			    width, flags);
			break;
		}
		case 'p': {
			void *p = va_arg(ap, void *);

			outn(&o, "0x", 2);
			fmt_int(&o, (uintptr_t)p, false, 16, false, -1,
			    0, 0);
			break;
		}
		case 'f':
		case 'F':
		case 'e':
		case 'E':
		case 'g':
		case 'G':
			fmt_float(&o, va_arg(ap, double), *fmt, prec,
			    width, flags);
			break;
		case 0:
			goto done;
		default:
			outc(&o, '%');
			outc(&o, *fmt);
			break;
		}
	}
done:
	if (o.cap)
		o.buf[o.pos < o.cap - 1 ? o.pos : o.cap - 1] = 0;
	return (int)o.pos;
}
