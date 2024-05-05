[BITS 16]
[CPU 8086]

; Author:   André Morales 
; Version:  1.1.0
; Creation: 07/10/2020
; Modified: 01/02/2022

%define STACK_ADDRESS 0xA00
%define PARTITION_ARRAY 0x1B00

; -- [0x0500 - 0x0A00] Stack
; -- [0x0A00 - 0x1A00] Loaded stage 2
; -- [0x1A00 - 0x1B00] Unitialiazed varible storage
; -- [0x1B00 - 0x1C00] Partition array
; -- [0x2000] Generic stuff buffer

#include "version.h"
#include <comm/strings.h>
#include <comm/console.h>
#include <comm/console_macros.h>
#include <comm/drive.h>

var short cursor
var byte partitionMapSize
var byte[6] partitionSizeStrBuff
var long extendedPartitionLBA

[SECTION .text]
db 'Xt' ; Two byte signature at binary beginning.

/* Entry point. */
Start: {
	mov sp, 0xA00 ; Readjust stack behind us

	push cs | pop ds        ; Copy CS [Segment 0xA0] to Data Segment
	xor ax, ax | mov es, ax ; Set ES to 0
	
	mov [Drive.id], dl                 ; Save drive number
	mov [Drive.CHS.bytesPerSector], di ; Save bytes per sector.
	
	sti                                ; Reenable interrupts that were disable back at stage 1.

	Print(."\N\n--- Xt Generic Boot Manager ---")
	Print(."\NVersion: $#VERSION#")
	
	; Set up division error int handler.
	mov word [es:0000], DivisionErrorHandler
	mov word [es:0002], ds
	
	call PrintCurrentVideoMode
	call GetDriveGeometry
	
	Print(."\NPress any key to read the partition map.") 
	call WaitKey
	
	mov di, PARTITION_ARRAY
	mov word [Drive.bufferPtr], 0x2000
	call ReadPartitionMap
	
	Print(."\NPartition map read.")
	mov ax, di
	sub ax, PARTITION_ARRAY
	
	mov cl, 10 | div cl
	mov [partitionMapSize], al
	
	Print(."\NPress any key to enter boot select...\N")
	call WaitKey
	jmp Menu
}

Menu: {
	mov word [cursor], 0
	
	MainMenu:
		ClearScreen(0_110_1111b)
		mov bx, 00_00h
		mov ax, 25_17h
		call drawSquare
	
		mov dx, 00_02h | call setCursor
		
		Print(."-XtBootMgr v$#VERSION# [Drive 0x")
		
		xor ah, ah | mov al, [Drive.id]
		PrintHexNum(ax)
		Print(."]-")
	
	MenuSelect:	
		call DrawMenu	
			
		call Getch
		cmp ah, 48h | je .upKey
		cmp ah, 50h | je .downKey
		cmp ah, 1Ch | je .enterKey
		jmp MenuSelect
		
		.upKey:
			mov ax, [cursor]
			test ax, ax | jnz .L3
			
			mov al, [partitionMapSize]
			
			.L3:
			dec ax
			div byte [partitionMapSize]
			mov [cursor], ah
		jmp MenuSelect
		
		.downKey:
			mov ax, [cursor]
			inc ax
			div byte [partitionMapSize]
			mov [cursor], ah
		jmp MenuSelect
		
		.enterKey:
			mov al, 10 | mul byte [cursor]
			mov di, ax
			add di, PARTITION_ARRAY
			
			cmp byte [es:di + 0], 05h | jne .L4
			Print(."\N\N You can't boot an extended partition.")
			jmp BackToMainMenu
			
			.L4: {	
				push di
				
				; Fill 0x7C00 with no-ops.
				mov di, 0x7C00
				mov al, 90h
				mov cx, 512
				rep stosb
				
				; Copy the boot failure handler after the boot sector. If control gets there, this handles it.
				mov si, BootFailureHandler
				mov cx, 16
				rep movsw
			
				pop di
			}
						
			Print(."\N\NReading drive...")
			push word [es:di + 4] | push word [es:di + 2] 
			mov word [Drive.bufferPtr], 0x7C00
			call Drive.ReadSector						
			
			cmp word [es:0x7DFE], 0xAA55 | jne .notBootable
			Print(."\NPress any key to boot...\N")	
			call WaitKey
			jmp .chain		
			
			.notBootable:
			Print(."\NBoot signature not found.\NBoot anyway [Y/N]?\N")	
			call Getch	
			cmp ah, 15h | jne BackToMainMenu.clear
			
			.chain:
			ClearScreen(0_000_0111b)
			
			mov dl, [Drive.id]
			jmp 0x0000:0x7C00	
		
		BackToMainMenu:
			call WaitKey
			.clear:
		jmp MainMenu
}

; void (ES:DI pntrToPartitionArray)
ReadPartitionMap: {
	CLSTACK
	ENTERFN
	
	push ds

	; Read MBR (Sector 0)
	xor ax, ax
	push ax | push ax
	call Drive.ReadSector
	test ax, ax | je .ReadTable ; Did it read properly?
	
	; AX is not 0. It failed somehow.
	Print(."\NSector read failed. The error was:\N ")
	cmp ax, 1 | je .OutOfRangeCHS
	Print(."Unknown")
	jmp .ErrorOut
	
	.OutOfRangeCHS:
	Print(."CHS (Cylinder) address out of range")
	
	.ErrorOut:
	Print(.".\NIgnoring the partitions at this sector.")
	jmp .End
	
	.ReadTable: {	
		{
			; Iterate partition table backwards. Since we'll push to the stack and pop the entries later, the 
			; order will be corrected. We need to save the entries to the stack because we are reading from the
			; temporary buffer [0x2000], reading another sector will override this area.
			xor bx, bx
			mov ds, bx
			mov si, 0x2000 + 0x1BE + 48 
			mov cx, 4
			.SavePartitionEntries:
				mov al, [ds:si + 4] ; Get partition type
				test al, al | jnz .storeEntry ; Is entry empty?
				jmp .endlspe
				
				.storeEntry:			
				; Save total sector count
				push word [ds:si + 14] ; High
				push word [ds:si + 12] ; Low
				
				; Save starting LBA to stack
				push word [ds:si + 10] ; High
				push word [ds:si + 8]  ; Low
				xor ah, ah | push ax  ; Store the partition type followed by 0 (primary partition)
				inc bx
			
				.endlspe:
				sub si, 16
			loop .SavePartitionEntries
		}
		
		{
			mov ds, [bp - 2]				
			mov cx, bx
			test cx, cx | jz .End
			.LoadPartitionEntries:
				; Get and store partition type to ES:DI and keep it on BL
				pop ax | stosw
				mov bl, al
				
				; Get and store LBA to ES:DI.
				pop ax | stosw ; Low  [DI - 8]
				pop ax | stosw ; High [DI - 6]
				
				; Get and store total sectors.
				pop ax | stosw ; Low  [DI - 4]
				pop ax | stosw ; High [DI - 2]
				
				cmp bl, 05h | jne .endllpe ; Is it and extended partition?
				mov dx, [es:di - 6]
				mov ax, [es:di - 8]
				mov [extendedPartitionLBA], ax
				mov [extendedPartitionLBA + 2], dx
				call ExploreExtendedPartitionChain
				.endllpe:
			loop .LoadPartitionEntries			
		}
	}
	
	.End:
	LEAVEFN
}

ExploreExtendedPartitionChain: {
	push bp
	mov bp, sp
	
	push ax ; [BP - 2]
	push dx ; [BP - 4]
	push ds ; [BP - 6]
	push es ; [BP - 8]
	push cx ; [BP - 10]
	
	push dx | push ax
	call Drive.ReadSector
	
	{
		xor ax, ax | mov ds, ax
		mov si, 0x2000 + 0x1BE
		; -- Read first partition entry --
		add si, 4
		lodsb             ; Get partition type
		mov ah, 1 | stosw ; Store partition type followed by 1 (logical partition)
		
		add si, 3
		lodsw
		add ax, word [bp - 2]
		stosw
		
		lodsw
		adc ax, word [bp - 4]
		stosw
		
		movsw
		movsw
		
		; -- Read second partition entry --
		add si, 4
		lodsb
		cmp al, 05h | jne .End ; Is there a link to the next logical partition?
		
		{
			mov es, [bp - 6] ; Put old DS (0xA0) into ES
			add si, 3
			lodsw
			add ax, word [es:extendedPartitionLBA]
			mov bx, ax
			
			lodsw
			adc ax, word [es:extendedPartitionLBA + 2]
			
			mov dx, ax
			mov ax, bx
			mov ds, [bp - 6]
			mov es, [bp - 8]
			call ExploreExtendedPartitionChain
		}	
	}
	
	.End:
	pop cx
	pop es
	pop ds
	mov sp, bp
	pop bp
ret }

/* Prints current video mode and number of columns. */
PrintCurrentVideoMode: {
	mov ah, 0Fh | int 10h
	push ax
	
	Print(."\NCurrent video mode: 0x")
	
	xor ah, ah
	PrintHexNum(ax)
	
	Print(."\NColumns: ")
	pop ax
	mov al, ah
	xor ah, ah
	call printDecNum	
ret }

GetDriveGeometry: {	
	call Drive.Init
	call Drive.CHS.GetProperties
	call Drive.LBA.GetProperties

	Print(."\N\N[Geometries of drive: ")
	xor ah, ah
	mov al, [Drive.id]
	PrintHexNum(ax)
	Print(."h] ")
	
	Print(."\N-- CHS")
	Print(."\N Bytes per Sector: ")
	PrintDecNum [Drive.CHS.bytesPerSector]
	
	Print(."\N Sectors per Track: ")
	xor ah, ah
	mov al, [Drive.CHS.sectorsPerTrack]
	call printDecNum

	Print(."\N Heads Per Cylinder: ")
	PrintDecNum [Drive.CHS.headsPerCylinder]
	
	Print(."\N Cylinders: ")
	PrintDecNum [Drive.CHS.cylinders]
	 
	Print(."\N-- LBA")
	
	mov al, [Drive.LBA.available]
	test al, al | jz .printLBAProps
	cmp al, 1   | je .noDriveLBA
	Print(."\N The BIOS doesn't support LBA.")
	jmp .End
	
	.noDriveLBA:
	Print(."\N The drive doesn't support LBA.")
	jmp .End
	
	.printLBAProps:
	Print(."\N Bytes per Sector: ")
	PrintDecNum [Drive.LBA.bytesPerSector]
	
	.End:
ret }
	
DrawMenu: {
	CLSTACK
	lvar short sectorsPerMB
	ENTERFN
	
	mov word [$sectorsPerMB], 2048
	push ds
	push es
	
	mov dx, 02_02h | call setCursor
		
	mov di, PARTITION_ARRAY
	xor cl, cl
	cmp cl, [partitionMapSize] | je .End ; If partition map is empty.
	
	.drawPartition:
		xor ax, ax | mov es, ax
		
		call setCursor
		mov bh, ' '  ; (Prefix) = ' '
		mov bl, 0x6F ; (Color) = White on orange.
		cmp cl, [cursor] | jne .printIndent ; Is this the selected item? If not, skip.
		
		; Item is selected
		add bh, '>' - ' ' ; Set prefix char to '>'
		cmp byte [es:di], 05h | jne .itemBootable ; Is this an extend partition type? If it is, set the bg to blue.
		mov bl, 0x4F                              ; Unbootable item selected color, white on red.
		jmp .printIndent
		
		.itemBootable:
		mov bl, 0x1F ; Bootable item selected color, white on blue.		
		
		; Print and extra indent if listing primary partitions.
		.printIndent:
		cmp byte [es:di + 1], 0 ; Listing primary partitions?
		je .printTypeName
		Putch(' ')
		
		.printTypeName:	
		Putch(bh)		
		mov al, [es:di] ; Partition type
		call getPartitionTypeName
		mov al, bl | call printColor
				
		PrintColor ." (", bl
		{
			push dx | push di
			
			mov ax, [es:di + 6]
			mov dx, [es:di + 8]
			div word [$sectorsPerMB]
			
			mov si, partitionSizeStrBuff
			mov es, [bp - 4] ; Set ES to DS
			mov di, si
			call Strings.IntToStr
			
			mov al, bl
			call printColor
			
			pop di | pop dx
		}
		
		PrintColor ." MiB)", bl
		
		add di, 10
		inc dh
		inc cx
	cmp cl, [partitionMapSize] | jne .drawPartition

	.End:
	pop es
	mov sp, bp
	pop bp
ret }

getPartitionTypeName: {
	push bx
	
	mov bl, al
	xor bh, bh
	mov bl, [PartitionTypeNamePtrIndexArr + bx]	
	add bx, bx
	mov si, [PartitionTypeNamePtrArr + bx]
	
	pop bx
ret }
	
drawSquare: {
	push bp
	mov bp, sp
	push ax
	
	xor ch, ch
	
	; Top box row
	mov dx, bx
	call setCursor
	
	Putch(0xC9)
	Putnch 0xCD, [bp - 1]
	Putch(0xBB)
	
	; Left box column
	mov dx, bx	
	mov al, 0xBA
	
	mov cl, [bp - 2]
	.leftC:
		inc dh
		call setCursor	
		call putch
	loop .leftC
	
	inc dh
	call setCursor	
	
	; Bottom box row
	Putch(0xC8)
	Putnch 0xCD, [bp - 1]
	Putch(0xBC)
	
	; Right box row
	mov dx, bx
	add dl, [bp - 1]
	inc dl
	mov al, 0xBA
	mov cl, [bp - 2]
	.rightC:
		inc dh
		call setCursor	
		call putch
	loop .rightC	
	
	mov sp, bp
	pop bp
ret }

clearRect: {
	push bp
	mov bp, sp
	push ax | push bx | push cx | push dx
	
	mov ax, 0600h    ; AH = Scroll up, AL = Clear
	mov bh, [bp + 8] ; Foreground / Background
	mov cx, [bp + 6] ; Origin
	mov dx, [bp + 4] ; Destination
	int 10h
		
	pop dx | pop cx | pop bx | pop ax
	pop bp
ret 6 }

clearScreen: {
	push ax
	xor ax, ax           | push ax
	mov ax, 18_27h       | push ax
	call clearRect
	
	xor dx, dx
	call setCursor
ret }

/* CHS calculation may fail and throw execution here. */ 
DivisionErrorHandler: {
	push bp
	mov bp, sp
	push ax | push bx | push cx | push dx
	push si | push di
	push ds
	
	push cs | pop ds
	Print(."\NDivision overflow or division by zero.\r")
	Print(."\NError occurred at: ")
	PrintHexNum word [bp + 4]
	Print(."h:")
	PrintHexNum word [bp + 2]
	Print(."h\NAX: 0x") | PrintHexNum word [bp - 2]
	Print(." BX: 0x") | PrintHexNum word [bp - 4]
	Print(." CX: 0x") | PrintHexNum word [bp - 6]
	Print(." DX: 0x") | PrintHexNum word [bp - 8]
	Print(."\NSP: 0x")
	lea ax, [bp + 8]
	PrintHexNum(ax)
	Print(." BP: 0x") | PrintHexNum word [bp - 0]
	Print(." SI: 0x") | PrintHexNum word [bp - 10]
	Print(." DI: 0x") | PrintHexNum word [bp - 12]
	Print(."\NSystem halted.")
	cli | hlt
}


/* When booting a partition fails. Handlers throw execution here. */
BootFailureHandler: {
	jmp 0x00A0:.L1
	
	.L1:
	push cs | pop ds
	Print(."\NXtBootMgr got control back. The bootsector either contains no executable code, or invalid code.\NGoing back to the main menu.")
	call WaitKey
	jmp Menu
}

printColor: {
	push ax
	push bx
	push cx
	push dx
	
	; Save color
	xor bh, bh
	mov bl, al
	push bx
	
	; Get cursor position
	mov ah, 03h
	xor bh, bh
	int 10h

	pop bx ; Get color back
	
	.char:
		lodsb
		test al, al
		jz .end
		
		cmp al, 0Ah
		je .putraw
		cmp al, 0Dh
		je .putraw
		
		; Print only at cursor position with color
		mov ah, 09h
		mov cx, 1
		int 10h
		
		; Set cursor position
		inc dl ; Increase X
		mov ah, 02h
		int 10h
	jmp .char
	
	.putraw:
		; Teletype output
		mov ah, 0Eh
		int 10h
		
		; Get cursor position
		mov ah, 03h
		int 10h
	jmp .char
	
	.end:
	pop dx
	pop cx
	pop bx
	pop ax
ret }	

getCursor: {
	push ax
	push bx
	push cx
	
	mov ah, 03h
	xor bh, bh
	int 10h
	
	pop cx
	pop bx
	pop ax
ret }

setCursor: {
	push ax
	push bx
	push cx
	push dx 
	
	mov ah, 02h ; Set cursor position
	xor bh, bh
	int 10h
	
	pop dx
	pop cx
	pop bx
	pop ax
ret }

PartitionTypeNamePtrIndexArr: {
	db 0, 1, 1, 1, 1, 5, 2, 6
	db 1, 1, 1, 3, 1, 1, 7, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 4, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
	db 1, 1, 1, 1, 1, 1, 1, 1
}

PartitionTypeNamePtrArr: {
	dw ."Empty"
	dw ."Unknown"
	dw ."FAT / RAW"
	dw ."FAT32"
	dw ."Linux"
	dw ."Extended Partition"
	dw ."NTFS"
	dw ."FAT(12/16)"
}

@rodata:

[SECTION .bss]
@bss:
