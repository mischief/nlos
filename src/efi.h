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
typedef int16_t   INT16;
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

#define EVT_TIMER		0x80000000
#define EVT_NOTIFY_SIGNAL	0x00000200
#define TPL_CALLBACK		8

typedef enum {
	TimerCancel,
	TimerPeriodic,
	TimerRelative
} EFI_TIMER_DELAY;
#define EFI_ERROR(s)		(((INTN)(s)) < 0)
#define EFI_NOT_READY		(0x8000000000000000ULL | 6)
#define EFI_NO_MAPPING		(0x8000000000000000ULL | 17)
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

/* a handful of Simple Text Input ScanCode values (UEFI spec table):
 * non-unicode keys report UnicodeChar=0 and a ScanCode instead. most
 * are true special keys (arrows, F-keys) with no ASCII equivalent,
 * but SCAN_DELETE is the odd one out -- OVMF's console reports the
 * physical Backspace key this way (UnicodeChar=0, ScanCode=8) rather
 * than as CHAR_BACKSPACE (0x08) the way Ctrl-H arrives, so it needs
 * explicit handling instead of being silently dropped.
 */
#define SCAN_DELETE	0x0008

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

/* device paths (enough to identify the com2 serial controller) */

#define END_DEVICE_PATH_TYPE	0x7f
#define ACPI_DEVICE_PATH	0x02	/* Type */
#define ACPI_DP			0x01	/* SubType: ACPI(_HID,_UID) */

/* compressed EISA id for "PNP0501" (16550 serial): (0x0501 << 16) | 0x41d0 */
#define EISA_PNP_ID_SERIAL	0x050141d0

typedef struct EFI_DEVICE_PATH_PROTOCOL {
	UINT8 Type;
	UINT8 SubType;
	UINT8 Length[2];	/* little-endian, includes this header */
} EFI_DEVICE_PATH_PROTOCOL;

typedef struct {
	EFI_DEVICE_PATH_PROTOCOL Header;
	UINT32 HID;
	UINT32 UID;
} ACPI_HID_DEVICE_PATH;

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

	EFI_STATUS (EFIAPI *CreateEvent)(UINT32 Type, UINTN NotifyTpl,
	    void *NotifyFunction, void *NotifyContext, EFI_EVENT *Event);
	EFI_STATUS (EFIAPI *SetTimer)(EFI_EVENT Event, int Type,
	    UINT64 TriggerTime);
	EFI_STATUS (EFIAPI *WaitForEvent)(UINTN NumberOfEvents, EFI_EVENT *Event,
	    UINTN *Index);
	EFI_STATUS (EFIAPI *SignalEvent)(EFI_EVENT Event);
	EFI_STATUS (EFIAPI *CloseEvent)(EFI_EVENT Event);
	EFI_STATUS (EFIAPI *CheckEvent)(EFI_EVENT Event);

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

	/* uefi 1.1 driver model (we only need a few) */
	void *ConnectController;
	EFI_STATUS (EFIAPI *DisconnectController)(EFI_HANDLE Controller,
	    EFI_HANDLE DriverImageHandle, EFI_HANDLE ChildHandle);
	void *OpenProtocol;
	void *CloseProtocol;
	void *OpenProtocolInformation;
	void *ProtocolsPerHandle;
	EFI_STATUS (EFIAPI *LocateHandleBuffer)(int SearchType,
	    EFI_GUID *Protocol, void *SearchKey, UINTN *NoHandles,
	    EFI_HANDLE **Buffer);
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

typedef struct EFI_SERVICE_BINDING_PROTOCOL EFI_SERVICE_BINDING_PROTOCOL;
struct EFI_SERVICE_BINDING_PROTOCOL {
	EFI_STATUS (EFIAPI *CreateChild)(EFI_SERVICE_BINDING_PROTOCOL *This,
	    EFI_HANDLE *ChildHandle);
	EFI_STATUS (EFIAPI *DestroyChild)(EFI_SERVICE_BINDING_PROTOCOL *This,
	    EFI_HANDLE ChildHandle);
};

/* ---- tcp4: async, token/Event-based -- see src/net.c and
 * kernel_new_net_event. field order/sizes follow the UEFI spec
 * exactly; these are called through function pointers, so layout is
 * abi, not style.
 */

typedef struct {
	BOOLEAN UseDefaultAddress;
	UINT8 StationAddress[4];
	UINT8 SubnetMask[4];
	UINT16 StationPort;
	UINT8 RemoteAddress[4];
	UINT16 RemotePort;
	BOOLEAN ActiveFlag;
} EFI_TCP4_ACCESS_POINT;

typedef struct {
	UINT8 TypeOfService;
	UINT8 TimeToLive;
	EFI_TCP4_ACCESS_POINT AccessPoint;
	void *ControlOption;	/* EFI_TCP4_OPTION*; NULL is fine */
} EFI_TCP4_CONFIG_DATA;

typedef struct {
	EFI_EVENT Event;
	EFI_STATUS Status;
} EFI_TCP4_COMPLETION_TOKEN;

typedef struct {
	EFI_TCP4_COMPLETION_TOKEN CompletionToken;
} EFI_TCP4_CONNECTION_TOKEN;

typedef struct {
	EFI_TCP4_COMPLETION_TOKEN CompletionToken;
	EFI_HANDLE NewChildHandle;
} EFI_TCP4_LISTEN_TOKEN;

typedef struct {
	EFI_TCP4_COMPLETION_TOKEN CompletionToken;
	BOOLEAN AbortOnClose;
} EFI_TCP4_CLOSE_TOKEN;

typedef struct {
	UINT32 FragmentLength;
	void *FragmentBuffer;
} EFI_TCP4_FRAGMENT_DATA;

typedef struct {
	BOOLEAN UrgentFlag;
	UINT32 DataLength;
	UINT32 FragmentCount;
	EFI_TCP4_FRAGMENT_DATA FragmentTable[1];
} EFI_TCP4_RECEIVE_DATA;

typedef struct {
	BOOLEAN Push;
	BOOLEAN Urgent;
	UINT32 DataLength;
	UINT32 FragmentCount;
	EFI_TCP4_FRAGMENT_DATA FragmentTable[1];
} EFI_TCP4_TRANSMIT_DATA;

typedef struct {
	EFI_TCP4_COMPLETION_TOKEN CompletionToken;
	union {
		EFI_TCP4_RECEIVE_DATA *RxData;
		EFI_TCP4_TRANSMIT_DATA *TxData;
	} Packet;
} EFI_TCP4_IO_TOKEN;

typedef struct EFI_TCP4_PROTOCOL EFI_TCP4_PROTOCOL;
struct EFI_TCP4_PROTOCOL {
	EFI_STATUS (EFIAPI *GetModeData)(EFI_TCP4_PROTOCOL *This,
	    void *Tcp4State, EFI_TCP4_CONFIG_DATA *Tcp4ConfigData,
	    void *Ip4ModeData, void *MnpConfigData, void *SnpModeData);
	EFI_STATUS (EFIAPI *Configure)(EFI_TCP4_PROTOCOL *This,
	    EFI_TCP4_CONFIG_DATA *TcpConfigData);
	EFI_STATUS (EFIAPI *Routes)(EFI_TCP4_PROTOCOL *This,
	    BOOLEAN DeleteRoute, UINT8 *SubnetAddress, UINT8 *SubnetMask,
	    UINT8 *GatewayAddress);
	EFI_STATUS (EFIAPI *Connect)(EFI_TCP4_PROTOCOL *This,
	    EFI_TCP4_CONNECTION_TOKEN *ConnectionToken);
	EFI_STATUS (EFIAPI *Accept)(EFI_TCP4_PROTOCOL *This,
	    EFI_TCP4_LISTEN_TOKEN *ListenToken);
	EFI_STATUS (EFIAPI *Transmit)(EFI_TCP4_PROTOCOL *This,
	    EFI_TCP4_IO_TOKEN *Token);
	EFI_STATUS (EFIAPI *Receive)(EFI_TCP4_PROTOCOL *This,
	    EFI_TCP4_IO_TOKEN *Token);
	EFI_STATUS (EFIAPI *Close)(EFI_TCP4_PROTOCOL *This,
	    EFI_TCP4_CLOSE_TOKEN *CloseToken);
	EFI_STATUS (EFIAPI *Cancel)(EFI_TCP4_PROTOCOL *This,
	    EFI_TCP4_COMPLETION_TOKEN *Token);
	EFI_STATUS (EFIAPI *Poll)(EFI_TCP4_PROTOCOL *This);
};

typedef struct {
	UINT16 Year;
	UINT8 Month;
	UINT8 Day;
	UINT8 Hour;
	UINT8 Minute;
	UINT8 Second;
	UINT8 Pad1;
	UINT32 Nanosecond;
	INT16 TimeZone;
	UINT8 Daylight;
	UINT8 Pad2;
} EFI_TIME;

/* ---- udp4: connectionless sibling of tcp4 above -- same token/Event
 * async shape (Transmit/Receive, no Connect/Accept since there's no
 * connection), field order/sizes again exactly per spec, verified
 * against MdePkg/Include/Protocol/Udp4.h.
 */

typedef struct {
	BOOLEAN AcceptBroadcast;
	BOOLEAN AcceptPromiscuous;
	BOOLEAN AcceptAnyPort;
	BOOLEAN AllowDuplicatePort;
	UINT8 TypeOfService;
	UINT8 TimeToLive;
	BOOLEAN DoNotFragment;
	UINT32 ReceiveTimeout;
	UINT32 TransmitTimeout;
	BOOLEAN UseDefaultAddress;
	UINT8 StationAddress[4];
	UINT8 SubnetMask[4];
	UINT16 StationPort;
	UINT8 RemoteAddress[4];
	UINT16 RemotePort;
} EFI_UDP4_CONFIG_DATA;

typedef struct {
	UINT8 SourceAddress[4];
	UINT16 SourcePort;
	UINT8 DestinationAddress[4];
	UINT16 DestinationPort;
} EFI_UDP4_SESSION_DATA;

typedef struct {
	UINT32 FragmentLength;
	void *FragmentBuffer;
} EFI_UDP4_FRAGMENT_DATA;

typedef struct {
	EFI_UDP4_SESSION_DATA *UdpSessionData;	/* NULL: use configured default */
	UINT8 *GatewayAddress;			/* NULL: fine for our use */
	UINT32 DataLength;
	UINT32 FragmentCount;
	EFI_UDP4_FRAGMENT_DATA FragmentTable[1];
} EFI_UDP4_TRANSMIT_DATA;

typedef struct {
	EFI_TIME TimeStamp;
	EFI_EVENT RecycleSignal;
	EFI_UDP4_SESSION_DATA UdpSession;
	UINT32 DataLength;
	UINT32 FragmentCount;
	EFI_UDP4_FRAGMENT_DATA FragmentTable[1];
} EFI_UDP4_RECEIVE_DATA;

typedef struct {
	EFI_EVENT Event;
	EFI_STATUS Status;
	union {
		EFI_UDP4_RECEIVE_DATA *RxData;
		EFI_UDP4_TRANSMIT_DATA *TxData;
	} Packet;
} EFI_UDP4_COMPLETION_TOKEN;

typedef struct EFI_UDP4_PROTOCOL EFI_UDP4_PROTOCOL;
struct EFI_UDP4_PROTOCOL {
	EFI_STATUS (EFIAPI *GetModeData)(EFI_UDP4_PROTOCOL *This,
	    EFI_UDP4_CONFIG_DATA *Udp4ConfigData, void *Ip4ModeData,
	    void *MnpConfigData, void *SnpModeData);
	EFI_STATUS (EFIAPI *Configure)(EFI_UDP4_PROTOCOL *This,
	    EFI_UDP4_CONFIG_DATA *UdpConfigData);
	EFI_STATUS (EFIAPI *Groups)(EFI_UDP4_PROTOCOL *This,
	    BOOLEAN JoinFlag, UINT8 *MulticastAddress);
	EFI_STATUS (EFIAPI *Routes)(EFI_UDP4_PROTOCOL *This,
	    BOOLEAN DeleteRoute, UINT8 *SubnetAddress, UINT8 *SubnetMask,
	    UINT8 *GatewayAddress);
	EFI_STATUS (EFIAPI *Transmit)(EFI_UDP4_PROTOCOL *This,
	    EFI_UDP4_COMPLETION_TOKEN *Token);
	EFI_STATUS (EFIAPI *Receive)(EFI_UDP4_PROTOCOL *This,
	    EFI_UDP4_COMPLETION_TOKEN *Token);
	EFI_STATUS (EFIAPI *Cancel)(EFI_UDP4_PROTOCOL *This,
	    EFI_UDP4_COMPLETION_TOKEN *Token);
	EFI_STATUS (EFIAPI *Poll)(EFI_UDP4_PROTOCOL *This);
};

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
