/* Head (Stage 2)
 *
 * Author:   André Morales 
 * Version:  0.7.0
 * Creation: 02/01/2021
 * Modified: 05/05/2023
 */

;                # Memory Map #
; -- [0x 500 -  ...  ] Where Stage 3 file will be loaded
; -- [0x 700 -  ...  ] Where Stage 3 code begins
; -- [0x3000 -  ...  ] FAT16 Cluster Buffer
; -- [0x6000 -  ...  ] Stage 2 (Us)
; -- [0x7C00 - 0x7DFF] Our VBR still loaded
; -- [0x7E00 - 0x7FFF] Stack

[BITS 16]
[CPU 8086]

; How many sectors this stage takes up
%define SECTORS 6
#define FATX_DEBUG 1
#define CONSOLE_MIRROR_TO_SERIAL 1

; Include a few macro definition files
#include "version.h"
#include <common/console.h>
#include <common/serial.h>

[SECTION .text]
; Stores in the file our signature and sector count which
; then are used by Stage 1 to indentify and load us.
db 'Xt'
dw SECTORS  

start: {
	; Clear segments
	xor ax, ax
	mov ds, ax
	mov es, ax
	
	; Get beginning sector pushed by boot_head
	pop word [FATFS.beginningSct]      
	pop word [FATFS.beginningSct + 2]
	
	; Setup stack
	mov ss, ax
	mov sp, 0x7FF0

	; Configure free interrupt 30h to halt the system if we need
	mov word [0x30 * 4 + 0], Halt ; Setup interrupt 0x30 to Halt
	mov word [0x30 * 4 + 2], 0
	
	; Store drive number
	mov [Drive.id], dl
	
	; Print header
	Print(."\n-- &bZk&3Loader &4Head &cv$#VERSION#\n")
	
	; Initialize serial
	call Serial.init	
	Log(."I Serial ready.\n")
	
	; Configure a buffer region and temporary storage to process the file system
	mov word [Drive.bufferPtr], 0x0500
	mov word [FATFS.clusterBuffer], 0x2000
	
	call InitDrive
	call InitFileSystem
	
	;0 ..
	;1 Ok
	;2 In
	;3 Wr
	;4 ER
	
	Log(."I Press any key to load BSTRAP.BIN.\n")
	call WaitKey
	call Load_LdrHeadBin

	; Copy all Drive variables to the pointer stored in Stage 3.
	mov si, Drive
	mov di, [0x702]
	mov cx, Drive.vars_end - Drive
	rep movsb 
	
	; Copy all FATFS variables to the pointer stored in Stage 3.
	mov si, FATFS
	mov di, [0x704]
	mov cx, FATFS.vars_end - FATFS
	rep movsb 
	
	; Check the signature
	cmp word [0x500], 'Zk' | je .jump
	Log(."E Invalid signature.\n")
	int 0x30

; Jump to Stage 3.
.jump:
	Log(.". Jumping...\n")
	jmp 0x700
}

; -- Load XTOS/BSTRAP.BIN
Load_LdrHeadBin: {
	mov si, ."ZKOS       /BSTRAP  BIN"
	push si
	call FATFS.LocateFile
	Log(."K Found.\n")
	
	mov word [Drive.bufferPtr], 0x500
	
	push ax
	call FATFS.ReadClusterChain
	
	Log(."K Loaded.\n")
ret }

FileNotFoundOnDir: {
	push si
	Print(."\nFile '")
	;mov si, [FATFS.filePathPtr]
	pop si
	call print
	
	Print(."' not found on directory.")
	int 30h
}


Halt: {
	Log(."E System halted.")
	cli | hlt
}

InitFileSystem: {
	Log(."I Partition config:")
	
	push ds 
	
	push ds | pop es
	xor ax, ax | mov ds, ax

	mov ax, 0x7C00 | push ax
	call FATFS.Initialize
	
	pop ds	
	
	Print(."\n  FAT")
	
	xor ah, ah
	mov al, [FATFS.clusterBits]
	call printDecNum
	
	Print(.": ")
	Print(FATFS.label)
	
	Print(."\n  Start: 0x")
	PrintHexNum word [FATFS.beginningSct + 2]
	Putch(':')
	PrintHexNum word [FATFS.beginningSct]
	
	Serial.Print(."\n  FAT: 0x")
	Serial.PrintHexNum word [FATFS.fatSct + 2]
	Serial.Print(':')
	Serial.PrintHexNum word [FATFS.fatSct]
	
	Serial.Print(."\n  Root Dir: 0x")
	Serial.PrintHexNum word [FATFS.rootDirSct + 2]
	Serial.Print(':')
	Serial.PrintHexNum word [FATFS.rootDirSct]

	Serial.Print(."\n  Data: 0x")
	Serial.PrintHexNum word [FATFS.dataAreaSct + 2]
	Serial.Print(':')
	Serial.PrintHexNum word [FATFS.dataAreaSct]
	
	Print(."\n  Reserved L. Sectors: ")
	PrintDecNum [FATFS.reservedLogicalSectors] 
	
	Print(."\n  Total L. Sectors: ")
	PrintDecNum [FATFS.totalLogicalSectors] 
	
	Print(."\n  FATs: ")
	PrintDecNum [FATFS.fats]
	
	Print(."\n  Bytes per L. Sector: ")
	PrintDecNum [FATFS.bytesPerLogicalSector] 
	Print(."\n  L. Sectors per Cluster: ")
	PrintDecNum [FATFS.logicalSectorsPerCluster] 
	Print(."\n  Bytes per Cluster: ")
	PrintDecNum [FATFS.bytesPerCluster] 
	Print(."\n  L. Sectors per FAT: ")
	PrintDecNum [FATFS.logicalSectorsPerFAT] 
	Print(."\n")
ret }

InitDrive: {	
	call Drive.Init
	call Drive.CHS.GetProperties
	call Drive.LBA.GetProperties

	Log(."I Drive [")
	xor ah, ah
	mov al, [Drive.id]
	PrintHexNum(ax)
	Print(."] geometry:")
	
	Print(."\n CHS (AH = 02h)")
	Print(."\n  Bytes per Sector: ")
	PrintDecNum [Drive.CHS.bytesPerSector]
	
	Print(."\n  Sectors per Track: ")
	xor ah, ah
	mov al, [Drive.CHS.sectorsPerTrack]
	call printDecNum

	Print(."\n  Heads Per Cylinder: ")
	PrintDecNum [Drive.CHS.headsPerCylinder]
	
	Print(."\n  Cylinders: ")
	PrintDecNum [Drive.CHS.cylinders]
	
	Print(."\n LBA (AH = 48h)")
	
	mov al, [Drive.LBA.available]
	test al, al | jz .printLBAProps
	cmp al, 1   | je .noDriveLBA
	Print(."\n  The BIOS doesn't support LBA.")
	jmp .End
	
	.noDriveLBA:
	Print(."\n  The drive doesn't support LBA.")
	jmp .End
	
	.printLBAProps:
	Print(."\n  Bytes per Sector: ")
	PrintDecNum [Drive.LBA.bytesPerSector]
		
	.End:
	Print(."\n")
ret }

; Include defitions of a few commonly used functions
#include <common/console.asm>
#include <common/drive.asm>
#include <common/fat1x.asm>
#include <common/serial.asm>

@rodata:
times (512 * SECTORS)-($-$$) db 0x90 ; Round to 1kb.

; --------- Variable space ---------
[SECTION .bss]
@bss:
