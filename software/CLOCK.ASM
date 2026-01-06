.8086
.model tiny

; ==== Defines ====
NMI_MASK        equ 080h

RTC_INDEX_PORT  equ 070h
RTC_DATA_PORT   equ 071h

RTC_SEC_REG     equ 00h
RTC_MIN_REG     equ 02h
RTC_HR_REG      equ 04h
RTC_A_REG       equ 0Ah
RTC_B_REG       equ 0Bh
RTC_C_REG       equ 0Ch

RTC_RS_MASK     equ 0Fh
RTC_IE_MASK     equ 070h
RTC_PIE_BIT     equ 040h
RTC_UIE_BIT     equ 010h
RTC_PF_BIT      equ 040h
RTC_UF_BIT      equ 010h
RTC_RS_256HZ    equ 08h

PIC1_CMD_PORT   equ 020h
PIC1_DATA_PORT  equ 021h
PIC2_CMD_PORT   equ 0A0h
PIC2_DATA_PORT  equ 0A1h
PIC_EOI_CMD     equ 020h

; ==== 74HC595 + 74HCT74 cascade pin mapping ====
;
; SER -> [ C | 8 | 4 | 2 | 1 | A4 | A3 | A2 ] -> [ A1 ]
;
; Legend:
;  A1-A4    - Anodes for digits 1-4
;  C        - Colon cathode
;  1,2,4,8  - Digit in BCD format
;
; LPT pin mapping:
;  D0 - SER   (serial data input)
;  D1 - SRCLK (shift register clock)
;  D2 - RCLK  (latch register clock)

LPT_DATA_PORT   equ 0378h
LPT_SER_MASK    equ 01h
LPT_SRCLK_MASK  equ 02h
LPT_RCLK_MASK   equ 04h

SHIFT_REG_SIZE  equ 9  ; 74HC595 + 74HCT74
REG_COLON_MASK  equ 0100h

DISPLAY_COUNT   equ 4

.code
org 100h

; The initial entry point *must* be placed at 100h, but we don't need to keep
; the initialization part resident. Let's just jump to it instead and place it
; further in code so we can simply ignore it when determining TSR size.
entry_point:
    jmp init

; ==== Resident variables ====
disp_digits     db 0, 0, 0, 0           ; Time digits
disp_colon      db 0                    ; Colon state
disp_index      db 0                    ; Display index for multiplexing
disp_anode_lut  db 01h, 02h, 04h, 08h   ; LUT for anode control
slot_machine    db 0                    ; State of 'slot machine' effect - cathode depoisoning

; ==== Resident procedures ====

; Clobbers AX, CL
rtc_get_time proc
    mov slot_machine, 0; Disable slot machine effect

    mov al, RTC_SEC_REG
    out RTC_INDEX_PORT, al
    in al, RTC_DATA_PORT        ; Read seconds from RTC
    mov ah, al
    and al, 1                   ; Keep only LSB
    mov disp_colon, al          ; Store in memory as colon state

    mov al, RTC_MIN_REG
    out RTC_INDEX_PORT, al
    in al, RTC_DATA_PORT        ; Read minutes from RTC

    test ah, ah                 ; Check if seconds are zero
    jnz process_time
    test al, al                 ; Check if minutes are zero
    jnz process_time

    mov slot_machine, 1         ; If both seconds and minutes are zero, enable slot machine effect
    jmp get_time_end

process_time:
    mov ah, al
    and ah, 0F0h                ; AH = tens digit in upper nibble
    mov cl, 4
    shl al, cl                  ; AL = ones digit in upper nibble
    mov disp_digits + 3, al     ; Store ones in memory
    mov disp_digits + 2, ah     ; Store tens in memory

    mov al, RTC_HR_REG
    out RTC_INDEX_PORT, al
    in al, RTC_DATA_PORT        ; Read hours from RTC
    mov ah, al
    and ah, 0F0h                ; AH = tens digit in upper nibble
    mov cl, 4
    shl al, cl                  ; AL = ones digit in upper nibble
    mov disp_digits + 1, al     ; Store ones in memory
    mov disp_digits + 0, ah     ; Store tens in memory

get_time_end:
    ret
rtc_get_time endp

; Clobbers AX, BX, CX, DX
display_update proc
    ; Create new output state in DX
    xor dx, dx
    mov al, disp_index
    mov bx, offset disp_anode_lut
    xlatb
    mov dl, al                      ; DL = anode select bit
    mov al, disp_index
    mov bx, offset disp_digits
    xlatb
    or dl, al                       ; Add digit bits
    mov ah, slot_machine
    test ah, ah                     ; Check if slot machine effect enabled
    jz skip_increment
    add al, 10h                     ; Increment current digit (stored in upper nibble!)
    cmp al, 90h
    jbe store_increment             ; Check if above 9
    xor al, al                      ; If above, set to zero
store_increment:
    xor bx, bx
    mov bl, disp_index
    add bx, offset disp_digits
    mov [bx], al                    ; Write incremented value to memory
skip_increment:
    mov al, disp_colon
    test al, al                     ; If colon enabled...
    jz write_start
    or dx, REG_COLON_MASK           ; ...set colon output

    ; Write new state to shift register
write_start:
    mov bx, dx
    mov cx, SHIFT_REG_SIZE
    mov dx, LPT_DATA_PORT
write_loop:
    mov al, bl
    and al, LPT_SER_MASK            ; Keep only LSB (SER pin is wired to D0, so this is enough)
    out dx, al                      ; Write to port
    xor al, LPT_SRCLK_MASK
    out dx, al                      ; Clock to high
    xor al, LPT_SRCLK_MASK
    out dx, al                      ; Clock to low
    shr bx, 1                       ; Move to next bit
    loop write_loop

    ; Latch new data
    xor al, LPT_RCLK_MASK
    out dx, al                      ; Latch to high
    xor al, LPT_RCLK_MASK
    out dx, al                      ; Latch to low

    ; Select next display mod 4
    inc disp_index
    and disp_index, DISPLAY_COUNT - 1

    ret
display_update endp

rtc_isr proc
    ; Preserve used registers
    pushf
    push ax
    push bx
    push cx
    push dx
    push ds
    push cs
    pop ds                  ; Set DS = CS

    ; Read RTC register C
    mov al, RTC_C_REG
    out RTC_INDEX_PORT, al
    in al, RTC_DATA_PORT
    mov bl, al

    ; If update interrupt, update time variables
    test bl, RTC_UF_BIT
    jz check_pf
    call rtc_get_time

check_pf:
    ; If periodic interrupt, update display
    test bl, RTC_PF_BIT
    jz isr_exit
    call display_update

isr_exit:
    ; Send EOI to PICs
    mov al, PIC_EOI_CMD
    out PIC2_CMD_PORT, al   ; EOI to slave PIC
    out PIC1_CMD_PORT, al   ; EOI to master PIC

    ; Restore registers
    pop ds
    pop dx
    pop cx
    pop bx
    pop ax
    popf
    iret
rtc_isr endp

; ==== End of resident code ====
resident_end:

; ==== Non-resident variables ====
startup_msg db 'LPT clock TSR',0Dh,0Ah,'(C) Lefucjusz, Warszawa 2025',0Dh,0Ah,'$'
success_msg db 'Clock TSR up and running!',0Dh,0Ah,'$'

; ==== Non-resident initialization code ====
init:
    ; Display startup message
    mov ah, 09h
    mov dx, offset startup_msg
    int 21h

    ; Disable interrupts
    cli

    ; Install RTC IRQ8 handler (INT 70h)
    mov dx, offset rtc_isr
    mov ax, 2570h                       ; Set interrupt vector function (25h) for INT 70h
    int 21h

    ; Configure RTC to generate periodic interrupt with 256Hz rate and update-ended interrupt
    mov al, RTC_A_REG OR NMI_MASK       ; Select RTC register A, mask NMI
    out RTC_INDEX_PORT, al
    in al, RTC_DATA_PORT                ; Read the register
    and al, NOT RTC_RS_MASK             ; Clear Rate Selector bits
    or al, RTC_RS_256HZ                 ; Set periodic interrupt rate to 256Hz
    out RTC_DATA_PORT, al               ; Write to RTC

    mov al, RTC_B_REG OR NMI_MASK       ; Select RTC register B, mask NMI
    out RTC_INDEX_PORT, al
    in al, RTC_DATA_PORT                ; Read the register
    and al, NOT RTC_IE_MASK             ; Clear interrupt enable flags
    or al, RTC_PIE_BIT OR RTC_UIE_BIT   ; Enable periodic interrupt and update-ended interrupt
    out RTC_DATA_PORT, al               ; Write to RTC

    ; Unmask IRQ8
    in al, PIC2_DATA_PORT               ; Read slave PIC data port
    and al, 0FEh                        ; Unmask IRQ line 0 (IRQ8)
    out PIC2_DATA_PORT, al              ; Write to PIC

    ; Pre-fetch time
    call rtc_get_time

    ; Enable interrupts
    sti

    ; Display success message
    mov ah, 09h
    mov dx, offset success_msg
    int 21h

    ; Stay resident
    mov dx, offset resident_end     ; Get offset of the end of resident part
    add dx, 15
    mov cl, 4
    shr dx, cl                      ; Convert to paragraphs using (offset + 15) / 16 formula
    mov ax, 3100h                   ; Terminate & stay resident (31h) with return code 0
    int 21h
end entry_point
