/* minimal UEFI definitions, enough for console + files + memory. */

#ifndef EFI_H
#define EFI_H

#include <stdint.h>
#include <stddef.h>

/* the uefi calling convention is per-arch: microsoft x64 on x86_64,
 * and on aarch64 plain aapcs64 -- which is already what we compile to,
 * so EFIAPI is empty there. this is the only arch conditional outside
 * src/<arch>/, and it is unavoidable: it is part of the abi, not of
 * any one machine's code.
 */
#if defined(__x86_64__)
#define EFIAPI __attribute__((ms_abi))
#else
#define EFIAPI
#endif

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

/* one entry of the memory map. the map is an array of these, but the
 * FIRMWARE decides their size and GetMemoryMap reports it -- so walk by
 * that stride and never by sizeof, or firmware carrying an extra field
 * misreads every entry after the first.
 */
typedef struct {
	UINT32 Type;
	UINT32 Pad;
	EFI_PHYSICAL_ADDRESS PhysicalStart;
	EFI_PHYSICAL_ADDRESS VirtualStart;
	UINT64 NumberOfPages;
	UINT64 Attribute;
} EFI_MEMORY_DESCRIPTOR;

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

/* pci io: how src/aarch64/uart.c reaches the 16550 behind the 9p wire.
 * x86_64 gets at its uart with two instructions; on a machine with no
 * port io the same chip sits on pci, and asking the firmware where it
 * landed beats hardcoding one qemu machine's ecam and io window.
 */

typedef enum {
	EfiPciIoWidthUint8,
	EfiPciIoWidthUint16,
	EfiPciIoWidthUint32,
	EfiPciIoWidthUint64,
	EfiPciIoWidthFifoUint8,		/* Count accesses to ONE offset */
	EfiPciIoWidthFifoUint16,
	EfiPciIoWidthFifoUint32,
	EfiPciIoWidthFifoUint64
} EFI_PCI_IO_PROTOCOL_WIDTH;

typedef enum {
	EfiPciIoAttributeOperationGet,
	EfiPciIoAttributeOperationSet,
	EfiPciIoAttributeOperationEnable,
	EfiPciIoAttributeOperationDisable,
	EfiPciIoAttributeOperationSupported
} EFI_PCI_IO_PROTOCOL_ATTRIBUTE_OPERATION;

#define EFI_PCI_IO_ATTRIBUTE_IO	0x0001

typedef struct EFI_PCI_IO_PROTOCOL EFI_PCI_IO_PROTOCOL;

typedef EFI_STATUS (EFIAPI *EFI_PCI_IO_PROTOCOL_IO_MEM)(
    EFI_PCI_IO_PROTOCOL *This, EFI_PCI_IO_PROTOCOL_WIDTH Width,
    UINT8 BarIndex, UINT64 Offset, UINTN Count, void *Buffer);

typedef struct {
	EFI_PCI_IO_PROTOCOL_IO_MEM Read;
	EFI_PCI_IO_PROTOCOL_IO_MEM Write;
} EFI_PCI_IO_PROTOCOL_ACCESS;

typedef EFI_STATUS (EFIAPI *EFI_PCI_IO_PROTOCOL_CONFIG)(
    EFI_PCI_IO_PROTOCOL *This, EFI_PCI_IO_PROTOCOL_WIDTH Width,
    UINT32 Offset, UINTN Count, void *Buffer);

typedef struct {
	EFI_PCI_IO_PROTOCOL_CONFIG Read;
	EFI_PCI_IO_PROTOCOL_CONFIG Write;
} EFI_PCI_IO_PROTOCOL_CONFIG_ACCESS;

struct EFI_PCI_IO_PROTOCOL {
	void *PollMem;
	void *PollIo;
	EFI_PCI_IO_PROTOCOL_ACCESS Mem;
	EFI_PCI_IO_PROTOCOL_ACCESS Io;
	EFI_PCI_IO_PROTOCOL_CONFIG_ACCESS Pci;
	void *CopyMem;
	void *Map;
	void *Unmap;
	void *AllocateBuffer;
	void *FreeBuffer;
	void *Flush;
	void *GetLocation;
	EFI_STATUS (EFIAPI *Attributes)(EFI_PCI_IO_PROTOCOL *This,
	    EFI_PCI_IO_PROTOCOL_ATTRIBUTE_OPERATION Operation,
	    UINT64 Attributes, UINT64 *Result);
	void *GetBarAttributes;
	void *SetBarAttributes;
	UINT64 RomSize;
	void *RomImage;
};

/* boot services (prefixes of the real table; unused slots are void*) */
typedef struct {
	EFI_TABLE_HEADER Hdr;

	void *RaiseTPL;
	void *RestoreTPL;

	EFI_STATUS (EFIAPI *AllocatePages)(EFI_ALLOCATE_TYPE Type,
	    EFI_MEMORY_TYPE MemoryType, UINTN Pages,
	    EFI_PHYSICAL_ADDRESS *Memory);
	EFI_STATUS (EFIAPI *FreePages)(EFI_PHYSICAL_ADDRESS Memory, UINTN Pages);
	EFI_STATUS (EFIAPI *GetMemoryMap)(UINTN *MemoryMapSize,
	    EFI_MEMORY_DESCRIPTOR *MemoryMap, UINTN *MapKey,
	    UINTN *DescriptorSize, UINT32 *DescriptorVersion);
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

/* GetInfo(EFI_FILE_INFO_ID) metadata, and what Read() returns for each
 * entry when the handle is a directory rather than a file. FileName is a
 * variable-length CHAR16 array, so Size covers the whole record and the
 * struct can only be used as a view over a caller-supplied buffer --
 * never sizeof'd for allocation.
 */
#define EFI_FILE_READ_ONLY	0x0000000000000001ULL
#define EFI_FILE_HIDDEN		0x0000000000000002ULL
#define EFI_FILE_SYSTEM		0x0000000000000004ULL
#define EFI_FILE_DIRECTORY	0x0000000000000010ULL
#define EFI_FILE_ARCHIVE	0x0000000000000020ULL

typedef struct {
	UINT64 Size;		/* of this whole record, name included */
	UINT64 FileSize;
	UINT64 PhysicalSize;
	EFI_TIME CreateTime;
	EFI_TIME LastAccessTime;
	EFI_TIME ModificationTime;
	UINT64 Attribute;
	CHAR16 FileName[];
} EFI_FILE_INFO;

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

/* ---- tcp4: async, token/Event-based. field order/sizes follow the
 * UEFI spec exactly; these are called through function pointers, so
 * layout is abi, not style.
 *
 * Nothing in the kernel uses these any more -- we take the card from
 * the firmware and run our own stack over SNP. They are kept for
 * test/tcp4echo, the standalone diagnostic that established how EFI
 * completion events behave (see docs/uefi-notes.md), which is the only
 * thing left that speaks TCP4.
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

/* ---- simple network (snp), per MdePkg/Include/Protocol/SimpleNetwork.h
 *
 * The firmware's ethernet driver with nothing on top: frames in, frames
 * out, and the card's own address. Everything above it -- arp, ip, the
 * checksum, tcp -- is ours in Lua, which is the same stack microvm runs
 * over virtio-net, so one implementation serves both machines.
 *
 * There is no interrupt to wait on here. Receive returns EFI_NOT_READY
 * when the card has nothing, so this is polled, unlike virtio-net's
 * line into the ioapic. That is what kernel.c's pump_eth has to be told.
 *
 * Only the members up to Transmit are used; the rest are declared so
 * the vtable offsets are right, because getting one wrong calls the
 * wrong function with the right arguments.
 */

#define EFI_SIMPLE_NETWORK_RECEIVE_UNICAST		0x01
#define EFI_SIMPLE_NETWORK_RECEIVE_MULTICAST		0x02
#define EFI_SIMPLE_NETWORK_RECEIVE_BROADCAST		0x04
#define EFI_SIMPLE_NETWORK_RECEIVE_PROMISCUOUS		0x08

/* GetStatus's InterruptStatus. Reporting clears them, which is why
 * snp.c calls GetStatus in one place and hands the bits around.
 */
#define EFI_SIMPLE_NETWORK_RECEIVE_INTERRUPT		0x01
#define EFI_SIMPLE_NETWORK_TRANSMIT_INTERRUPT		0x02
#define EFI_SIMPLE_NETWORK_COMMAND_INTERRUPT		0x04
#define EFI_SIMPLE_NETWORK_SOFTWARE_INTERRUPT		0x08

/* Mode->State */
#define EFI_SIMPLE_NETWORK_STOPPED	0
#define EFI_SIMPLE_NETWORK_STARTED	1
#define EFI_SIMPLE_NETWORK_INITIALIZED	2

#define EFI_MAX_MCAST_FILTER_CNT 16

typedef struct {
	UINT8 Addr[32];
} EFI_MAC_ADDRESS;

typedef struct {
	UINT32 State;
	UINT32 HwAddressSize;
	UINT32 MediaHeaderSize;
	UINT32 MaxPacketSize;
	UINT32 NvRamSize;
	UINT32 NvRamAccessSize;
	UINT32 ReceiveFilterMask;
	UINT32 ReceiveFilterSetting;
	UINT32 MaxMCastFilterCount;
	UINT32 MCastFilterCount;
	EFI_MAC_ADDRESS MCastFilter[EFI_MAX_MCAST_FILTER_CNT];
	EFI_MAC_ADDRESS CurrentAddress;
	EFI_MAC_ADDRESS BroadcastAddress;
	EFI_MAC_ADDRESS PermanentAddress;
	UINT8 IfType;
	BOOLEAN MacAddressChangeable;
	BOOLEAN MultipleTxSupported;
	BOOLEAN MediaPresentSupported;
	BOOLEAN MediaPresent;
} EFI_SIMPLE_NETWORK_MODE;

typedef struct EFI_SIMPLE_NETWORK_PROTOCOL EFI_SIMPLE_NETWORK_PROTOCOL;
struct EFI_SIMPLE_NETWORK_PROTOCOL {
	UINT64 Revision;
	EFI_STATUS (EFIAPI *Start)(EFI_SIMPLE_NETWORK_PROTOCOL *This);
	EFI_STATUS (EFIAPI *Stop)(EFI_SIMPLE_NETWORK_PROTOCOL *This);
	EFI_STATUS (EFIAPI *Initialize)(EFI_SIMPLE_NETWORK_PROTOCOL *This,
	    UINTN ExtraRxBufferSize, UINTN ExtraTxBufferSize);
	EFI_STATUS (EFIAPI *Reset)(EFI_SIMPLE_NETWORK_PROTOCOL *This,
	    BOOLEAN ExtendedVerification);
	EFI_STATUS (EFIAPI *Shutdown)(EFI_SIMPLE_NETWORK_PROTOCOL *This);
	EFI_STATUS (EFIAPI *ReceiveFilters)(EFI_SIMPLE_NETWORK_PROTOCOL *This,
	    UINT32 Enable, UINT32 Disable, BOOLEAN ResetMCastFilter,
	    UINTN MCastFilterCnt, EFI_MAC_ADDRESS *MCastFilter);
	EFI_STATUS (EFIAPI *StationAddress)(EFI_SIMPLE_NETWORK_PROTOCOL *This,
	    BOOLEAN Reset, EFI_MAC_ADDRESS *New);
	EFI_STATUS (EFIAPI *Statistics)(EFI_SIMPLE_NETWORK_PROTOCOL *This,
	    BOOLEAN Reset, UINTN *StatisticsSize, void *StatisticsTable);
	EFI_STATUS (EFIAPI *MCastIpToMac)(EFI_SIMPLE_NETWORK_PROTOCOL *This,
	    BOOLEAN IPv6, void *IP, EFI_MAC_ADDRESS *MAC);
	EFI_STATUS (EFIAPI *NvData)(EFI_SIMPLE_NETWORK_PROTOCOL *This,
	    BOOLEAN ReadWrite, UINTN Offset, UINTN BufferSize, void *Buffer);
	EFI_STATUS (EFIAPI *GetStatus)(EFI_SIMPLE_NETWORK_PROTOCOL *This,
	    UINT32 *InterruptStatus, void **TxBuf);
	EFI_STATUS (EFIAPI *Transmit)(EFI_SIMPLE_NETWORK_PROTOCOL *This,
	    UINTN HeaderSize, UINTN BufferSize, void *Buffer,
	    EFI_MAC_ADDRESS *SrcAddr, EFI_MAC_ADDRESS *DestAddr,
	    UINT16 *Protocol);
	EFI_STATUS (EFIAPI *Receive)(EFI_SIMPLE_NETWORK_PROTOCOL *This,
	    UINTN *HeaderSize, UINTN *BufferSize, void *Buffer,
	    EFI_MAC_ADDRESS *SrcAddr, EFI_MAC_ADDRESS *DestAddr,
	    UINT16 *Protocol);
	void *WaitForPacket;
	EFI_SIMPLE_NETWORK_MODE *Mode;
};

/* ---- graphics output (gop), per MdePkg/Include/Protocol/GraphicsOutput.h
 *
 * Blt is the only pixel path we use. FrameBufferBase is deliberately
 * left as a plain address we never dereference: it is meaningless when
 * PixelFormat is PixelBltOnly, and using it anywhere else would mean
 * writing a per-format packer for the three layouts below. Blt takes
 * EFI_GRAPHICS_OUTPUT_BLT_PIXEL -- always BGRx in that order, whatever
 * the hardware format is -- and the firmware does the conversion.
 */

typedef enum {
	PixelRedGreenBlueReserved8BitPerColor,
	PixelBlueGreenRedReserved8BitPerColor,
	PixelBitMask,
	PixelBltOnly,
	PixelFormatMax
} EFI_GRAPHICS_PIXEL_FORMAT;

typedef struct {
	UINT32 RedMask;
	UINT32 GreenMask;
	UINT32 BlueMask;
	UINT32 ReservedMask;
} EFI_PIXEL_BITMASK;

typedef struct {
	UINT32 Version;
	UINT32 HorizontalResolution;
	UINT32 VerticalResolution;
	EFI_GRAPHICS_PIXEL_FORMAT PixelFormat;
	EFI_PIXEL_BITMASK PixelInformation;
	UINT32 PixelsPerScanLine;
} EFI_GRAPHICS_OUTPUT_MODE_INFORMATION;

typedef struct {
	UINT32 MaxMode;
	UINT32 Mode;
	EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info;
	UINTN SizeOfInfo;
	EFI_PHYSICAL_ADDRESS FrameBufferBase;
	UINTN FrameBufferSize;
} EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE;

typedef struct {
	UINT8 Blue;
	UINT8 Green;
	UINT8 Red;
	UINT8 Reserved;
} EFI_GRAPHICS_OUTPUT_BLT_PIXEL;

typedef enum {
	EfiBltVideoFill,
	EfiBltVideoToBltBuffer,
	EfiBltBufferToVideo,
	EfiBltVideoToVideo,
	EfiGraphicsOutputBltOperationMax
} EFI_GRAPHICS_OUTPUT_BLT_OPERATION;

typedef struct EFI_GRAPHICS_OUTPUT_PROTOCOL EFI_GRAPHICS_OUTPUT_PROTOCOL;
struct EFI_GRAPHICS_OUTPUT_PROTOCOL {
	EFI_STATUS (EFIAPI *QueryMode)(EFI_GRAPHICS_OUTPUT_PROTOCOL *This,
	    UINT32 ModeNumber, UINTN *SizeOfInfo,
	    EFI_GRAPHICS_OUTPUT_MODE_INFORMATION **Info);
	EFI_STATUS (EFIAPI *SetMode)(EFI_GRAPHICS_OUTPUT_PROTOCOL *This,
	    UINT32 ModeNumber);
	/* Delta is the source buffer's stride IN BYTES, and 0 means "the
	 * rectangle is exactly Width wide". Passing a pixel count here is
	 * the classic Blt bug.
	 */
	EFI_STATUS (EFIAPI *Blt)(EFI_GRAPHICS_OUTPUT_PROTOCOL *This,
	    EFI_GRAPHICS_OUTPUT_BLT_PIXEL *BltBuffer,
	    EFI_GRAPHICS_OUTPUT_BLT_OPERATION BltOperation,
	    UINTN SourceX, UINTN SourceY, UINTN DestinationX,
	    UINTN DestinationY, UINTN Width, UINTN Height, UINTN Delta);
	EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *Mode;
};

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

/* ip4 config2: the interface's address policy. this is how a static
 * address gets set, and therefore how a DHCP client written in lua
 * installs the lease it negotiated. field order/sizes per spec,
 * verified against MdePkg/Include/Protocol/Ip4Config2.h.
 */

typedef enum {
	Ip4Config2DataTypeInterfaceInfo,
	Ip4Config2DataTypePolicy,
	Ip4Config2DataTypeManualAddress,
	Ip4Config2DataTypeGateway,
	Ip4Config2DataTypeDnsServer,
	Ip4Config2DataTypeMaximum
} EFI_IP4_CONFIG2_DATA_TYPE;

typedef enum {
	Ip4Config2PolicyStatic,
	Ip4Config2PolicyDhcp,
	Ip4Config2PolicyMax
} EFI_IP4_CONFIG2_POLICY;

typedef struct {
	UINT8 Address[4];
	UINT8 SubnetMask[4];
} EFI_IP4_CONFIG2_MANUAL_ADDRESS;

/* the interface's own facts. wanted for HwAddress: a DHCP client must
 * put the real MAC in chaddr, because the server keys the lease on it
 * and the IP4 stack will ARP for the address with that same MAC. a made
 * up one yields a lease nothing can actually use.
 */
typedef struct {
	UINT16 Name[32];		/* CHAR16 */
	UINT8 IfType;
	UINT32 HwAddressSize;
	UINT8 HwAddress[32];		/* EFI_MAC_ADDRESS */
	UINT8 StationAddress[4];
	UINT8 SubnetMask[4];
	UINT32 RouteTableSize;
	void *RouteTable;
} EFI_IP4_CONFIG2_INTERFACE_INFO;

typedef struct EFI_IP4_CONFIG2_PROTOCOL EFI_IP4_CONFIG2_PROTOCOL;
struct EFI_IP4_CONFIG2_PROTOCOL {
	EFI_STATUS (EFIAPI *SetData)(EFI_IP4_CONFIG2_PROTOCOL *This,
	    EFI_IP4_CONFIG2_DATA_TYPE DataType, UINTN DataSize, void *Data);
	EFI_STATUS (EFIAPI *GetData)(EFI_IP4_CONFIG2_PROTOCOL *This,
	    EFI_IP4_CONFIG2_DATA_TYPE DataType, UINTN *DataSize, void *Data);
	EFI_STATUS (EFIAPI *RegisterDataNotify)(
	    EFI_IP4_CONFIG2_PROTOCOL *This,
	    EFI_IP4_CONFIG2_DATA_TYPE DataType, EFI_EVENT Event);
	EFI_STATUS (EFIAPI *UnregisterDataNotify)(
	    EFI_IP4_CONFIG2_PROTOCOL *This,
	    EFI_IP4_CONFIG2_DATA_TYPE DataType, EFI_EVENT Event);
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
