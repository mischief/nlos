/* minimal UEFI definitions, enough for console + files + memory.
 * all firmware calls use the microsoft x64 calling convention.
 */

#ifndef EFI_H
#define EFI_H

#include <stdint.h>
#include <stddef.h>

#define EFIAPI __attribute__((ms_abi))

typedef uint8_t   UINT8;
typedef uint16_t  UINT16;
typedef uint32_t  UINT32;
typedef uint64_t  UINT64;
typedef int64_t   INT64;
typedef uint64_t  UINTN;
typedef int64_t   INTN;
typedef uint16_t  CHAR16;
typedef uint8_t   BOOLEAN;
typedef void      *EFI_HANDLE;
typedef void      *EFI_EVENT;
typedef UINTN     EFI_STATUS;
typedef UINT64    EFI_PHYSICAL_ADDRESS;
typedef UINT64    EFI_VIRTUAL_ADDRESS;

#define EFI_SUCCESS		0
#define EFI_ERROR(s)		(((INTN)(s)) < 0)
#define EFI_NOT_READY		(0x8000000000000000ULL | 6)
#define EFI_BUFFER_TOO_SMALL	(0x8000000000000000ULL | 5)

typedef struct {
	UINT32 Data1;
	UINT16 Data2;
	UINT16 Data3;
	UINT8  Data4[8];
} EFI_GUID;

typedef struct {
	UINT64 Signature;
	UINT32 Revision;
	UINT32 HeaderSize;
	UINT32 CRC32;
	UINT32 Reserved;
} EFI_TABLE_HEADER;

/* console */

typedef struct {
	UINT16 ScanCode;
	CHAR16 UnicodeChar;
} EFI_INPUT_KEY;

typedef struct EFI_SIMPLE_TEXT_INPUT_PROTOCOL EFI_SIMPLE_TEXT_INPUT_PROTOCOL;
struct EFI_SIMPLE_TEXT_INPUT_PROTOCOL {
	EFI_STATUS (EFIAPI *Reset)(EFI_SIMPLE_TEXT_INPUT_PROTOCOL *This,
	    BOOLEAN ExtendedVerification);
	EFI_STATUS (EFIAPI *ReadKeyStroke)(EFI_SIMPLE_TEXT_INPUT_PROTOCOL *This,
	    EFI_INPUT_KEY *Key);
	EFI_EVENT WaitForKey;
};

typedef struct EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL;
struct EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL {
	EFI_STATUS (EFIAPI *Reset)(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This,
	    BOOLEAN ExtendedVerification);
	EFI_STATUS (EFIAPI *OutputString)(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This,
	    CHAR16 *String);
	void *TestString;
	void *QueryMode;
	void *SetMode;
	void *SetAttribute;
	EFI_STATUS (EFIAPI *ClearScreen)(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This);
	void *SetCursorPosition;
	void *EnableCursor;
	void *Mode;
};

/* memory */

typedef enum {
	AllocateAnyPages,
	AllocateMaxAddress,
	AllocateAddress,
	MaxAllocateType
} EFI_ALLOCATE_TYPE;

typedef enum {
	EfiReservedMemoryType,
	EfiLoaderCode,
	EfiLoaderData,
	EfiBootServicesCode,
	EfiBootServicesData,
	EfiRuntimeServicesCode,
	EfiRuntimeServicesData,
	EfiConventionalMemory,
	EfiUnusableMemory,
	EfiACPIReclaimMemory,
	EfiACPIMemoryNVS,
	EfiMemoryMappedIO,
	EfiMemoryMappedIOPortSpace,
	EfiPalCode,
	EfiPersistentMemory,
	EfiMaxMemoryType
} EFI_MEMORY_TYPE;

/* boot services (prefixes of the real table; unused slots are void*) */

typedef struct {
	EFI_TABLE_HEADER Hdr;

	void *RaiseTPL;
	void *RestoreTPL;

	EFI_STATUS (EFIAPI *AllocatePages)(EFI_ALLOCATE_TYPE Type,
	    EFI_MEMORY_TYPE MemoryType, UINTN Pages,
	    EFI_PHYSICAL_ADDRESS *Memory);
	EFI_STATUS (EFIAPI *FreePages)(EFI_PHYSICAL_ADDRESS Memory, UINTN Pages);
	void *GetMemoryMap;
	EFI_STATUS (EFIAPI *AllocatePool)(EFI_MEMORY_TYPE PoolType, UINTN Size,
	    void **Buffer);
	EFI_STATUS (EFIAPI *FreePool)(void *Buffer);

	void *CreateEvent;
	void *SetTimer;
	EFI_STATUS (EFIAPI *WaitForEvent)(UINTN NumberOfEvents, EFI_EVENT *Event,
	    UINTN *Index);
	void *SignalEvent;
	void *CloseEvent;
	void *CheckEvent;

	void *InstallProtocolInterface;
	void *ReinstallProtocolInterface;
	void *UninstallProtocolInterface;
	EFI_STATUS (EFIAPI *HandleProtocol)(EFI_HANDLE Handle,
	    EFI_GUID *Protocol, void **Interface);
	void *Reserved;
	void *RegisterProtocolNotify;
	void *LocateHandle;
	void *LocateDevicePath;
	void *InstallConfigurationTable;

	void *LoadImage;
	void *StartImage;
	void *Exit;
	void *UnloadImage;
	void *ExitBootServices;

	void *GetNextMonotonicCount;
	EFI_STATUS (EFIAPI *Stall)(UINTN Microseconds);
	void *SetWatchdogTimer;
} EFI_BOOT_SERVICES;

/* files */

#define EFI_FILE_MODE_READ	0x0000000000000001ULL
#define EFI_FILE_MODE_WRITE	0x0000000000000002ULL
#define EFI_FILE_MODE_CREATE	0x8000000000000000ULL

typedef struct EFI_FILE_PROTOCOL EFI_FILE_PROTOCOL;
struct EFI_FILE_PROTOCOL {
	UINT64 Revision;
	EFI_STATUS (EFIAPI *Open)(EFI_FILE_PROTOCOL *This,
	    EFI_FILE_PROTOCOL **NewHandle, CHAR16 *FileName,
	    UINT64 OpenMode, UINT64 Attributes);
	EFI_STATUS (EFIAPI *Close)(EFI_FILE_PROTOCOL *This);
	EFI_STATUS (EFIAPI *Delete)(EFI_FILE_PROTOCOL *This);
	EFI_STATUS (EFIAPI *Read)(EFI_FILE_PROTOCOL *This,
	    UINTN *BufferSize, void *Buffer);
	EFI_STATUS (EFIAPI *Write)(EFI_FILE_PROTOCOL *This,
	    UINTN *BufferSize, void *Buffer);
	EFI_STATUS (EFIAPI *GetPosition)(EFI_FILE_PROTOCOL *This,
	    UINT64 *Position);
	EFI_STATUS (EFIAPI *SetPosition)(EFI_FILE_PROTOCOL *This,
	    UINT64 Position);
	EFI_STATUS (EFIAPI *GetInfo)(EFI_FILE_PROTOCOL *This,
	    EFI_GUID *InformationType, UINTN *BufferSize, void *Buffer);
	EFI_STATUS (EFIAPI *SetInfo)(EFI_FILE_PROTOCOL *This,
	    EFI_GUID *InformationType, UINTN BufferSize, void *Buffer);
	EFI_STATUS (EFIAPI *Flush)(EFI_FILE_PROTOCOL *This);
};

typedef struct EFI_SIMPLE_FILE_SYSTEM_PROTOCOL EFI_SIMPLE_FILE_SYSTEM_PROTOCOL;
struct EFI_SIMPLE_FILE_SYSTEM_PROTOCOL {
	UINT64 Revision;
	EFI_STATUS (EFIAPI *OpenVolume)(EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *This,
	    EFI_FILE_PROTOCOL **Root);
};

typedef struct {
	UINT32 Revision;
	EFI_HANDLE ParentHandle;
	void *SystemTable;
	EFI_HANDLE DeviceHandle;
	/* rest unused */
} EFI_LOADED_IMAGE_PROTOCOL;

/* runtime services (through ResetSystem) */

typedef enum {
	EfiResetCold,
	EfiResetWarm,
	EfiResetShutdown,
	EfiResetPlatformSpecific
} EFI_RESET_TYPE;

typedef struct {
	EFI_TABLE_HEADER Hdr;
	void *GetTime;
	void *SetTime;
	void *GetWakeupTime;
	void *SetWakeupTime;
	void *SetVirtualAddressMap;
	void *ConvertPointer;
	void *GetVariable;
	void *GetNextVariableName;
	void *SetVariable;
	void *GetNextHighMonotonicCount;
	void (EFIAPI *ResetSystem)(EFI_RESET_TYPE ResetType,
	    EFI_STATUS ResetStatus, UINTN DataSize, void *ResetData);
} EFI_RUNTIME_SERVICES;

typedef struct {
	EFI_TABLE_HEADER Hdr;
	CHAR16 *FirmwareVendor;
	UINT32 FirmwareRevision;
	EFI_HANDLE ConsoleInHandle;
	EFI_SIMPLE_TEXT_INPUT_PROTOCOL *ConIn;
	EFI_HANDLE ConsoleOutHandle;
	EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *ConOut;
	EFI_HANDLE StandardErrorHandle;
	EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *StdErr;
	EFI_RUNTIME_SERVICES *RuntimeServices;
	EFI_BOOT_SERVICES *BootServices;
	UINTN NumberOfTableEntries;
	void *ConfigurationTable;
} EFI_SYSTEM_TABLE;

extern EFI_SYSTEM_TABLE *ST;
extern EFI_BOOT_SERVICES *BS;
extern EFI_HANDLE self_image;

#endif
