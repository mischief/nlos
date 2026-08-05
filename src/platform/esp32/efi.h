/* kernel.c is written against a small slice of the EFI Boot Services /
 * System Table shape: one periodic timer event (create/set/check/wait)
 * and ConIn's ReadKeyStroke/WaitForKey. There is no firmware here, so
 * this is not a general EFI compat layer -- it defines exactly the
 * members kernel.c dereferences, named the same, so that file needs no
 * changes. src/platform/esp32/idf_shim.c backs
 * CreateEvent/SetTimer/CheckEvent/WaitForEvent/Stall with esp_timer and
 * a FreeRTOS delay; ConIn reads the IDF console, which is the same link
 * the tick-driven repl types into.
 */
#ifndef ESP32_EFI_H
#define ESP32_EFI_H

typedef unsigned long UINTN;
typedef long EFI_STATUS;

#define EFI_SUCCESS	0
#define EFI_NOT_READY	1

typedef void *EFI_EVENT;

#define EVT_TIMER	0x80000000
#define TPL_CALLBACK	8

typedef enum { TimerCancel, TimerPeriodic, TimerRelative } EFI_TIMER_DELAY;

typedef struct {
	unsigned short ScanCode;
	unsigned short UnicodeChar;
} EFI_INPUT_KEY;

#define SCAN_DELETE 9

typedef struct efi_simple_text_input {
	EFI_STATUS (*ReadKeyStroke)(struct efi_simple_text_input *self,
	    EFI_INPUT_KEY *key);
	EFI_EVENT WaitForKey;
} EFI_SIMPLE_TEXT_INPUT_PROTOCOL;

typedef struct {
	EFI_STATUS (*CreateEvent)(unsigned type, UINTN tpl, void *notify,
	    void *ctx, EFI_EVENT *out);
	EFI_STATUS (*SetTimer)(EFI_EVENT ev, EFI_TIMER_DELAY type,
	    unsigned long long triggertime_100ns);
	EFI_STATUS (*CheckEvent)(EFI_EVENT ev);
	EFI_STATUS (*WaitForEvent)(UINTN n, EFI_EVENT *evs, UINTN *index);
	void (*Stall)(UINTN microseconds);
} EFI_BOOT_SERVICES;

typedef struct {
	EFI_SIMPLE_TEXT_INPUT_PROTOCOL *ConIn;
} EFI_SYSTEM_TABLE;

extern EFI_BOOT_SERVICES *BS;
extern EFI_SYSTEM_TABLE *ST;

#endif
