; ============================================================
; made by asm_expand.py from rom32.masm: change that file, then run
;     python3 asm_expand.py rom32.masm
; ============================================================

; ============================================================
; rom32.masm - the 32K ROM image's own code: the loader that starts the
; DOS (DOS.PLC on the SD card) or BASIC, and runs programs from the card
; ============================================================
;
; The 32K image (docs/ROM.md "The 32K image") holds the boot loader, the
; library, the FAT writer and this code.  The DOS is a program on the SD
; card (DOS.PLC, dos.masm, docs/DOS.md); the ROM keeps only what has to
; outlive a program that loads over the DOS in the RAM:
;
;   power-up     "PLACARD" and about a second in which Esc held goes to the
;                DOS's file browser.  No card (or none it can read): BASIC.
;                Esc held: DOS.PLC.  Otherwise BOOT.CFG in the root folder
;                names the program to run ("MENU.PLC", or "BASIC"); with no
;                BOOT.CFG, DOS.PLC.  No DOS.PLC in the root folder: BASIC.
;   programs     .PLC files: 16-byte header ("PLC", type, load address,
;                length, entry), then the bytes.  Type 0 (a library
;                program) is copied to its load address in x0100-x3FFF and
;                entered with map 07, SP = FF, LIB_RAM in place; type 1 (a
;                RAM image, the older demos) to RAM x0000-x49FF, started at
;                x0000 with map FF through MB_GO.
;   coming back  a program jumps to x8008 (or a RAM image's hook goes
;                through MB_EXIT): the card is mounted again, the folder
;                put back, MB_PARENT run if a program set it (the demo
;                menu names itself), otherwise DOS.PLC loaded again from
;                the root folder (as COMMAND.COM was on MS-DOS).
;   errors       a file that can't be run: its error goes to MB_ERR
;                (FAT error 1-14, ERR_NOTPROG, ERR_ISDIR) and DOS.PLC
;                shows it.  DOS.PLC itself missing or bad: BASIC.
;
; VECTORS (x8000-x80FF), the fixed places a program may jump to or CALL:
;   x8000  the reset code (nop, jump to the boot loader): a 32K cartridge
;          reads it at x0000
;   x8008  dos_back    a program is done (map 05 or 07)
;   x800C  dos_run     R1:R0 = "NAME.PLC", 0 in RAM (current folder): load
;                      and run it (never returns)
;   x8010  fs_create   x8014 fs_write   x8018 fs_close   x801C fs_delete
;   x8020  fs_save     the FAT writer (placard_fsw.masm): CALL as a library
;                      routine, e.g.  ld 0x80, y / jmp 0x20  with LINK set
;   x8024  basic       BASIC (a jump; it never returns)
;
; RAM: zero page x20-x2B while the loader runs (a program's own x20-x5F
; are free again when it is entered), DOS_BUF x5400-x55FF and DOS_BUF0
; x5600-x57FF (the program's first sector, BOOT.CFG, a RAM image's page
; 0), the menu block x5D00-x5D6F (placard_menu.asm) and the FAT driver's
; x4D00-x4FFF.
;
; ROM: x8000-x80FF vectors, x8100-x9EFF and xA000-xAFFF this code and
; BASIC (asm_expand.py pages it), x9F00-x9FFF LIB_RAM's image (the boot
; reads it at x1F00 on a 32K cartridge), xB000-xBFFF the FAT writer.
;
;     python3 asm_expand.py rom32.masm        writes rom32.asm
;     build\rom32.bat                         the FPGA, rom_32k.bin
;     python3 test_dos.py                     runs it with a card image
;
; Date: 10/26/2026
; ============================================================

#include "placard.asm"
#include "placard_lib.asm"
#include "placard_fsw.asm"

ROM_CODE  = 0x8100      ; this code, up to LIB_RAM's image
ROM_TOP   = 0x9F00
ROM_CODE2 = 0xA000      ; and on after it, up to the FAT writer
ROM_TOP2  = 0xB000
BOOT      = 0xFD00      ; rom_boot.asm: the boot loader (its reset code jumps here)
BOOT_MODE = 0xFC00      ; the boot mode byte: 02 = the 32K image (jump to x8100)
MODE_32K  = 0x02
MAP_RUN   = 0x07        ; sections 0-2 RAM, 3-7 ROM
LIB_RAM_IMG = 0x9F00    ; LIB_RAM's bytes in the 32K image

DOS_BUF   = 0x5400      ; a sector: the program file's first, BOOT.CFG
DOS_BUF0  = 0x5600      ; a RAM image's page 0 until the loader lets go of the zero page
ESC_FRAMES = 60         ; about a second to hold Esc at power-up

; MB_ERR codes besides the FAT driver's 1-14 (placard_menu.asm)
ERR_NOTPROG = 0x80      ; not a .PLC file
ERR_ISDIR   = 0x81      ; a folder

; zero page (the loader's own; a program's x20-x5F are free again when it runs)
l_t     = 0x20          ; scratch
l_t2    = 0x21
l_c     = 0x22          ; a character
l_type  = 0x23          ; the program's type
l_ll    = 0x24          ; its load address
l_lh    = 0x25
l_cl    = 0x26          ; its length
l_ch    = 0x27
l_el    = 0x28          ; its entry
l_eh    = 0x29
l_esc   = 0x2A          ; 1 = Esc was held at power-up
l_dos   = 0x2B          ; 1 = loading DOS.PLC (from the root; a failure starts BASIC)

; ============================================================
; the vectors
; ============================================================

#addr 0x8000
    nop                         ; the reset code, as rom_boot.asm x0000-x0004
    ld   BOOT >> 8, y
    jmp  BOOT & 0xFF

#addr 0x8008
    ld   dos_back >> 8, y
    jmp  dos_back
    ld   dos_run >> 8, y
    jmp  dos_run
    ld   fs_create >> 8, y
    jmp  fs_create
    ld   fs_write >> 8, y
    jmp  fs_write
    ld   fs_close >> 8, y
    jmp  fs_close
    ld   fs_delete >> 8, y
    jmp  fs_delete
    ld   fs_save >> 8, y
    jmp  fs_save
    ld   basic >> 8, y
    jmp  basic


#addr 0x8100
power_up:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   MAP_RUN, ac
    ld   ac, [MAP_SHADOW]
    ld   0x50, y
    ld   MAP_RUN, [y,x]         ; map 07 (section 4, this code, stays ROM)
    ld   pu_block >> 8, y
    jmp  pu_block

pu_block:
    ld   MENU_BLK >> 8, y
    ld   MB_MAGIC, x
    ld   0x4D, [y,x]            ; "MNU"
    ld   MB_MAGIC + 1, x
    ld   0x4E, [y,x]
    ld   MB_MAGIC + 2, x
    ld   0x55, [y,x]
    ld   MB_MODE, x
    ld   1, [y,x]               ; picked: no time limit
    ld   MB_HOLD, x
    ld   600 & 0xFF, [y,x]
    ld   MB_HOLD + 1, x
    ld   600 >> 8, [y,x]
    ld   MB_WHY, x
    ld   0, [y,x]
    ld   MB_CHILD, x
    ld   0, [y,x]
    ld   MB_PARENT, x
    ld   0, [y,x]
    ld   MB_FNAME, x
    ld   0x5C, [y,x]            ; "\": the root
    ld   MB_FNAME + 1, x
    ld   0, [y,x]
    ld   MB_DCLUS, x            ; the root
    ld   0, [y,x]
    ld   MB_DCLUS + 1, x
    ld   0, [y,x]
    ld   MB_DCLUS + 2, x
    ld   0, [y,x]
    ld   MB_DCLUS + 3, x
    ld   0, [y,x]
    ld   0x1F, ac               ; x5D11-x5D1F (MB_MENU, MB_ERR, MB_SEL, MB_TOP ...) = 0
    ld   ac, [l_t]
pu_z:
    ld   [l_t], x
    ld   0, [y,x]
    ld   [l_t], ac
    dec
    ld   ac, [l_t]
    xor  0x10, ac
    bne  pu_z
    clr  ac                     ; MB_EXIT and MB_GO code into the RAM
    ld   ac, [l_t]
pu_cp:
    ld   [l_t], ac
    add  stubs & 0xFF, x
    ld   stubs >> 8, y
    ld   [y,x], ac
    ld   ac, [l_t2]
    ld   [l_t], ac
    add  MB_EXIT, x
    ld   MENU_BLK >> 8, y
    ld   [l_t2], ac
    ld   ac, [y,x]
    ld   [l_t], ac
    inc
    ld   ac, [l_t]
    xor  16, ac
    bne  pu_cp
    ld   pu_title >> 8, y
    jmp  pu_title

; it runs from
        ; the RAM because the fetch after a map write still uses the old map
stubs:
    ld   0x50, y                ; MB_EXIT: map 05, then dos_back through x8008
    ld   0x05, [y,x]
    ld   0x80, y
    jmp  0x08
    ld   0x50, y                ; MB_GO: map FF, the RAM image's reset
    ld   0xFF, [y,x]
    ld   0x00, y
    jmp  0x00

pu_basic:
    clr  ac
    ld   ac, [l_t]
pb_l:
    ld   [l_t], ac
    add  s_basic & 0xFF, x
    ld   s_basic >> 8, y
    ld   [y,x], ac
    ld   ac, [l_c]
    ld   [l_t], ac
    add  MB_CHILD, x
    ld   MENU_BLK >> 8, y
    ld   [y,x], ac
    ld   ac, [l_t2]
    sub  0x61, ac               ; a-z to A-Z
    blt  pb_u
    sub  0x1A, ac
    bcc  pb_u                   ; no borrow: past z
    ld   [l_t2], ac
    sub  0x20, ac
    ld   ac, [l_t2]
pb_u:
    ld   [l_t2], ac
    xor  [l_c], ac
    bne  pb_prog
    ld   [l_c], ac
    beq  pb_basic               ; all of it, and the 0
    ld   [l_t], ac
    inc
    ld   ac, [l_t]
    bra  pb_l
pb_basic:
    ld   basic >> 8, y
    jmp  basic
pb_prog:
    clr  ac
    ld   ac, [l_dos]
    ld   run_child >> 8, y
    jmp  run_child

; ============================================================
; dos_run (vector x800C) - run the file named at R1:R0
; dos_back (vector x8008) - a program is done
; start_dos - DOS.PLC from the root folder (BASIC when it can't)
; ============================================================
lib_ram_copy:
    clr  ac
    ld   ac, [l_t]
lrc:
    ld   [l_t], x
    ld   LIB_RAM_IMG >> 8, y
    ld   [y,x], ac
    ld   LIB_RAM >> 8, y
    ld   ac, [y,x]
    ld   [l_t], ac
    inc
    ld   ac, [l_t]
    bne  lrc
    ld   [LINK_HI], y
    jmp  [LINK_LO]

w_PREVLET_Q_:
    #d8 2, 114, 93, 23, 2, 0, 84, 37, 4, 4, 1, 0
    #d8 3, 7, 2, 114, 93, 23, 34, 25, 58, 0
pu_title:
    ld   LINK_LO, x             ; CALL con_clear
    ld   rom_r1, [x]
    ld   LINK_HI, x
    ld   rom_r1 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
rom_r1:
    ld   s_title & 0xFF, ac
    ld   ac, [R0]
    ld   s_title >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   rom_r2, [x]
    ld   LINK_HI, x
    ld   rom_r2 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
rom_r2:
    ld   2, ac
    ld   ac, [CUR_ROW]
    clr  ac
    ld   ac, [CUR_COL]
    ld   s_hold & 0xFF, ac
    ld   ac, [R0]
    ld   s_hold >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   rom_r3, [x]
    ld   LINK_HI, x
    ld   rom_r3 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
rom_r3:
    ld   LINK_LO, x             ; CALL port_init
    ld   rom_r4, [x]
    ld   LINK_HI, x
    ld   rom_r4 >> 8, [x]
    ld   port_init >> 8, y
    jmp  port_init
rom_r4:
    clr  ac
    ld   ac, [l_esc]
    ld   ESC_FRAMES, ac
    ld   ac, [l_t2]
pu_w:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames_io
    ld   rom_r5, [x]
    ld   LINK_HI, x
    ld   rom_r5 >> 8, [x]
    ld   wait_frames_io >> 8, y
    jmp  wait_frames_io
rom_r5:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   rom_r6, [x]
    ld   LINK_HI, x
    ld   rom_r6 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
rom_r6:
    ld   [KBD_NOW], ac          ; Esc is key 0: column 0, bit 0, 0 = down
    and  1, ac
    bne  pu_w1
    ld   1, ac
    ld   ac, [l_esc]
pu_w1:
    ld   [l_t2], ac
    dec
    ld   ac, [l_t2]
    bne  pu_w
    ld   [KBD_HEAD], ac         ; forget the keys pressed meanwhile
    ld   ac, [KBD_TAIL]
    ld   pu_card >> 8, y
    jmp  pu_card

pu_card:
    ld   LINK_LO, x             ; CALL mount
    ld   rom_r7, [x]
    ld   LINK_HI, x
    ld   rom_r7 >> 8, [x]
    ld   mount >> 8, y
    jmp  mount
rom_r7:
    beq  pu_c1
    ld   basic >> 8, y          ; no card: BASIC
    jmp  basic
pu_c1:
    ld   LINK_LO, x             ; the root
    ld   rom_r8, [x]
    ld   LINK_HI, x
    ld   rom_r8 >> 8, [x]
    ld   save_dclus >> 8, y
    jmp  save_dclus
rom_r8:
    ld   [l_esc], ac
    bne  pu_dos
    ld   s_cfg & 0xFF, ac       ; BOOT.CFG into DOS_BUF
    ld   ac, [R0]
    ld   s_cfg >> 8, ac
    ld   ac, [R1]
    ld   DOS_BUF & 0xFF, ac
    ld   ac, [R4]
    ld   DOS_BUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_load
    ld   rom_r9, [x]
    ld   LINK_HI, x
    ld   rom_r9 >> 8, [x]
    ld   fs_load >> 8, y
    jmp  fs_load
rom_r9:
    bne  pu_dos
    clr  ac                     ; MB_CHILD = its first word
    ld   ac, [l_t]
pu_cfg:
    ld   DOS_BUF >> 8, y
    ld   [l_t], x
    ld   [y,x], ac
    sub  0x21, ac
    blt  pu_cfge                ; space, CR, LF, 00: the end
    add  0x21, ac
    ld   ac, [l_c]
    ld   [l_t], ac
    add  MB_CHILD, x
    ld   MENU_BLK >> 8, y
    ld   [l_c], ac
    ld   ac, [y,x]
    ld   [l_t], ac
    inc
    ld   ac, [l_t]
    xor  12, ac
    bne  pu_cfg
pu_cfge:
    ld   [l_t], ac
    add  MB_CHILD, x
    ld   MENU_BLK >> 8, y
    ld   0, [y,x]
    ld   [l_t], ac
    beq  pu_dos                 ; an empty file
    ld   pu_basic >> 8, y
    jmp  pu_basic
pu_dos:
    ld   start_dos >> 8, y
    jmp  start_dos

w_ABS:
    #d8 12, 41, 4, 2, w_NEGATE >> 8, w_NEGATE & 0xFF, 0
dos_run:
    clr  ac
    ld   ac, [l_t]
dr_cp:
    ld   [R1], y
    ld   [R0], x
    ld   [y,x], ac
    ld   ac, [l_c]
    ld   [l_t], ac
    add  MB_CHILD, x
    ld   MENU_BLK >> 8, y
    ld   [l_c], ac
    ld   ac, [y,x]
    beq  dr_go
    ld   [l_t], ac
    inc
    ld   ac, [l_t]
    xor  12, ac
    beq  dr_go
    ld   [R0], ac
    inc
    ld   ac, [R0]
    bcc  dr_cp
    ld   [R1], ac
    inc
    ld   ac, [R1]
    bra  dr_cp
dr_go:
    ld   MENU_BLK >> 8, y
    ld   MB_CHILD + 12, x
    ld   0, [y,x]
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   LINK_LO, x             ; CALL remount
    ld   rom_r10, [x]
    ld   LINK_HI, x
    ld   rom_r10 >> 8, [x]
    ld   remount >> 8, y
    jmp  remount
rom_r10:
    clr  ac
    ld   ac, [l_dos]
    ld   run_child >> 8, y
    jmp  run_child

dos_back:
    ld   LINK_LO, x             ; CALL reinit
    ld   rom_r11, [x]
    ld   LINK_HI, x
    ld   rom_r11 >> 8, [x]
    ld   reinit >> 8, y
    jmp  reinit
rom_r11:
    ld   MENU_BLK >> 8, y
    ld   MB_PARENT, x
    ld   [y,x], ac
    beq  db_dos
    ld   12, ac                 ; the parent runs again: MB_CHILD = MB_PARENT
    ld   ac, [l_t]
db_cp:
    ld   [l_t], ac
    add  MB_PARENT, x
    ld   MENU_BLK >> 8, y
    ld   [y,x], ac
    ld   ac, [l_c]
    ld   [l_t], ac
    add  MB_CHILD, x
    ld   [l_c], ac
    ld   ac, [y,x]
    ld   [l_t], ac
    sub  1, ac
    ld   ac, [l_t]
    bcc  db_cp                  ; no borrow: more to copy
    ld   MB_PARENT, x
    ld   0, [y,x]
    clr  ac
    ld   ac, [l_dos]
    ld   run_child >> 8, y
    jmp  run_child
db_dos:
    ld   start_dos >> 8, y
    jmp  start_dos

start_dos:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   FSV, y                 ; no card mounted: BASIC
    ld   V_TYPE, x
    ld   [y,x], ac
    bne  sd_ok
    ld   basic >> 8, y
    jmp  basic
sd_ok:
    ld   1, ac
    ld   ac, [l_dos]
    ld   MENU_BLK >> 8, y
    ld   MB_PARENT, x
    ld   0, [y,x]
    ld   7, ac                  ; MB_CHILD = "DOS.PLC", 0
    ld   ac, [l_t]
sd_cp:
    ld   [l_t], ac
    add  s_dosplc & 0xFF, x
    ld   s_dosplc >> 8, y
    ld   [y,x], ac
    ld   ac, [l_c]
    ld   [l_t], ac
    add  MB_CHILD, x
    ld   MENU_BLK >> 8, y
    ld   [l_c], ac
    ld   ac, [y,x]
    ld   [l_t], ac
    sub  1, ac
    ld   ac, [l_t]
    bcc  sd_cp
    ld   FSV, y                 ; from the root: V_DCLUS = 0 (MB_DCLUS keeps the folder)
    ld   V_DCLUS, x
    ld   0, [y,x]
    ld   V_DCLUS + 1, x
    ld   0, [y,x]
    ld   V_DCLUS + 2, x
    ld   0, [y,x]
    ld   V_DCLUS + 3, x
    ld   0, [y,x]
    ld   run_child >> 8, y
    jmp  run_child

save_dclus:
    ld   3, ac
    ld   ac, [l_t]
sv_cp:
    ld   [l_t], ac
    add  V_DCLUS, x
    ld   FSV, y
    ld   [y,x], ac
    ld   ac, [l_c]
    ld   [l_t], ac
    add  MB_DCLUS, x
    ld   MENU_BLK >> 8, y
    ld   [l_c], ac
    ld   ac, [y,x]
    ld   [l_t], ac
    sub  1, ac
    ld   ac, [l_t]
    bcc  sv_cp
    ld   [LINK_HI], y
    jmp  [LINK_LO]

w__P__ST_:
    #d8 12, 19, 23, 27, 20, 24, 0
reinit:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   LINK_LO, x             ; CALL port_init
    ld   rom_r12, [x]
    ld   LINK_HI, x
    ld   rom_r12 >> 8, [x]
    ld   port_init >> 8, y
    jmp  port_init
rom_r12:
    ld   LINK_LO, x             ; CALL remount
    ld   rom_r13, [x]
    ld   LINK_HI, x
    ld   rom_r13 >> 8, [x]
    ld   remount >> 8, y
    jmp  remount
rom_r13:
    ld   lib_leave >> 8, y
    jmp  lib_leave

        ; leaves the port as the program had it: a key let go while
        ; port_init looks for the keyboard would make it miss it
remount:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   MAP_RUN, ac
    ld   ac, [MAP_SHADOW]
    ld   0x50, y
    ld   MAP_RUN, [y,x]
    ld   LINK_LO, x             ; CALL lib_ram_copy
    ld   rom_r14, [x]
    ld   LINK_HI, x
    ld   rom_r14 >> 8, [x]
    ld   lib_ram_copy >> 8, y
    jmp  lib_ram_copy
rom_r14:
    ld   LINK_LO, x             ; CALL mount
    ld   rom_r15, [x]
    ld   LINK_HI, x
    ld   rom_r15 >> 8, [x]
    ld   mount >> 8, y
    jmp  mount
rom_r15:
    bne  rm_x
    ld   LINK_LO, x             ; CALL get_dclus
    ld   rom_r16, [x]
    ld   LINK_HI, x
    ld   rom_r16 >> 8, [x]
    ld   get_dclus >> 8, y
    jmp  get_dclus
rom_r16:
rm_x:
    ld   lib_leave >> 8, y
    jmp  lib_leave

mount:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   [SP], ac
    dec
    ld   ac, x
    dec
    ld   ac, [SP]
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   [SAVE_AC], ac
    ld   LINK_LO, x             ; CALL sd_init
    ld   rom_r17, [x]
    ld   LINK_HI, x
    ld   rom_r17 >> 8, [x]
    ld   sd_init >> 8, y
    jmp  sd_init
rom_r17:
    bne  m_x
    ld   LINK_LO, x             ; CALL fs_mount
    ld   rom_r18, [x]
    ld   LINK_HI, x
    ld   rom_r18 >> 8, [x]
    ld   fs_mount >> 8, y
    jmp  fs_mount
rom_r18:
m_x:
    ld   lib_leave >> 8, y
    jmp  lib_leave

get_dclus:
    ld   3, ac
    ld   ac, [l_t]
gd_cp:
    ld   [l_t], ac
    add  MB_DCLUS, x
    ld   MENU_BLK >> 8, y
    ld   [y,x], ac
    ld   ac, [l_c]
    ld   [l_t], ac
    add  V_DCLUS, x
    ld   FSV, y
    ld   [l_c], ac
    ld   ac, [y,x]
    ld   [l_t], ac
    sub  1, ac
    ld   ac, [l_t]
    bcc  gd_cp
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; run_child - load and run the program named at MB_CHILD
; ============================================================
        ; DOS.PLC itself: BASIC
fail:
    ld   MENU_BLK >> 8, y
    ld   MB_ERR, x
    ld   ac, [y,x]
    ld   MB_PARENT, x           ; a menu does not get it back
    ld   0, [y,x]
    ld   [l_dos], ac
    bne  fl_basic
    ld   LINK_LO, x             ; the card again (a load may have stopped half way)
    ld   rom_r21, [x]
    ld   LINK_HI, x
    ld   rom_r21 >> 8, [x]
    ld   reinit >> 8, y
    jmp  reinit
rom_r21:
    ld   start_dos >> 8, y
    jmp  start_dos
fl_basic:
    ld   basic >> 8, y
    jmp  basic

w_HEXCH:
    #d8 12, 1, 9, w__GT_ >> 8, w__GT_ & 0xFF, 4, 3, 1, 7, 27, 1, 48
    #d8 27, 0
run_child:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   MB_CHILD, ac
    ld   ac, [R0]
    ld   MENU_BLK >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   rom_r19, [x]
    ld   LINK_HI, x
    ld   rom_r19 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
rom_r19:
    bne  rc_err
    ld   FSV, y
    ld   V_ENTRY + 11, x
    ld   [y,x], ac
    and  0x10, ac
    bne  rc_dir
    ld   DOS_BUF & 0xFF, ac     ; its first sector
    ld   ac, [R4]
    ld   DOS_BUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_read
    ld   rom_r20, [x]
    ld   LINK_HI, x
    ld   rom_r20 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
rom_r20:
    bne  rc_err
    ld   DOS_BUF >> 8, y
    ld   0, x
    ld   [y,x], ac
    xor  0x50, ac               ; "PLC"
    bne  rc_notp
    ld   1, x
    ld   [y,x], ac
    xor  0x4C, ac
    bne  rc_notp
    ld   2, x
    ld   [y,x], ac
    xor  0x43, ac
    bne  rc_notp
    ld   rc_header >> 8, y
    jmp  rc_header
rc_notp:
    ld   ERR_NOTPROG, ac
    ld   fail >> 8, y
    jmp  fail
rc_dir:
    ld   ERR_ISDIR, ac
rc_err:
    ld   fail >> 8, y
    jmp  fail

rc_header:
    ld   DOS_BUF >> 8, y
    ld   3, x
    ld   [y,x], ac
    ld   ac, [l_type]
    ld   4, x
    ld   [y,x], ac
    ld   ac, [l_ll]
    ld   5, x
    ld   [y,x], ac
    ld   ac, [l_lh]
    ld   6, x
    ld   [y,x], ac
    ld   ac, [l_cl]
    ld   7, x
    ld   [y,x], ac
    ld   ac, [l_ch]
    ld   8, x
    ld   [y,x], ac
    ld   ac, [l_el]
    ld   9, x
    ld   [y,x], ac
    ld   ac, [l_eh]
    ld   [l_type], ac
    bne  rc_t1
    ld   load_t0 >> 8, y
    jmp  load_t0
rc_t1:
    ld   load_t1 >> 8, y
    jmp  load_t1

        ; page 0 with no zero page of our own, go
lt1_go:
    ld   MENU_BLK >> 8, y
    ld   MB_KB, x
    ld   0, [y,x]
    ld   MB_IA, x
    ld   0, [y,x]
    ld   PORT, y
    ld   PORT_RX, x
    ld   P_KFREE, [y,x]
lt1_p0:
    ld   MENU_BLK >> 8, y
    ld   MB_IA, x
    ld   [y,x], ac
    ld   ac, x
    ld   DOS_BUF0 >> 8, y
    ld   [y,x], ac
    ld   0, y
    ld   ac, [y,x]
    ld   MENU_BLK >> 8, y
    ld   MB_IA, x
    ld   [y,x], ac
    inc
    ld   ac, [y,x]
    bne  lt1_p0
    ld   MENU_BLK >> 8, y
    jmp  MB_GO

; ============================================================
; strings
; ============================================================
s_title:    #d "PLACARD", 0x00
s_hold:     #d "Hold Esc for the file browser", 0x00
s_cfg:      #d "BOOT.CFG", 0x00
s_dosplc:   #d "DOS.PLC", 0x00
s_basic:    #d "BASIC", 0x00

; ============================================================
; BASIC (vector x8024): basic.masm and its bytecode, basic.vm, in the
; space left in both regions (docs/BASIC.md)
; ============================================================
; ============================================================
; basic.masm - PLACARD BASIC: the bytecode machine's native code
; ============================================================
;
; rom32.masm includes this file.  BASIC itself is written in bytecode
; (basic.vm, compiled by vmc.py when asm_expand.py meets the .include at
; the end of this file); this file is the machine that runs it and the
; primitives that have to be fast or touch the hardware.  docs/BASIC.md,
; "The bytecode machine", describes it:
;
;   IP     the next instruction (IPL, IPH)
;   TOS    the top cell of the data stack (TL, TH); the rest of the data
;          stack is in the zero page below DS_EMPTY, DSP = its top cell
;          (low byte at DSP, high byte at DSP + 1), growing down
;   RSP    the return stack in page RSTK: the top entry's low byte at
;          RSP + 1, high byte at RSP + 2, growing down from xFF
;
; An instruction byte x00-x3F runs the primitive of that number (through
; the page vm_jump, made by vmc.py from the PRIM lines of basic.vm, four
; bytes a primitive: ld hi, y / jmp lo); x80-xFF is the
; high byte of a word's address, the next byte its low byte: a call.
; Every primitive ends by jumping to next.
;
; The library is used as by any program (CALL, the stack at xC0-xFF);
; R0-R7 and T0-T7 are free between primitives.
;
; Date: 10/26/2026
; ============================================================

; the machine's zero page
IPL     = 0x20
IPH     = 0x21
TL      = 0x22
TH      = 0x23
DSP     = 0x24
RSP     = 0x25
W0      = 0x26          ; scratch for the primitives
W1      = 0x27
W2      = 0x28
W3      = 0x29
W4      = 0x2A
W5      = 0x2B
W6      = 0x2C
W7      = 0x2D
SPG     = 0x2E          ; ROWCPY: source page
DPG     = 0x2F          ; and destination page
; BASIC's zero page that the primitives use (basic.vm has the rest, x36-x4F)
TP      = 0x30          ; 2: the text pointer
TXTROWS = 0x32          ; text rows on the screen (the window)
TXT2X   = 0x33          ; 0: 80 x 60 text (1x rows), 1: 80 x 30 (2x rows)
LASTFR  = 0x34          ; FRAME_LO at the last POLL
DS_EMPTY = 0x90         ; the data stack: x50-x8F
RSTK    = 0x5500        ; the return stack page
B_RAM   = 0x5C          ; the page the RAM routines are copied to


; ------------------------------------------------------------
; macros
; ------------------------------------------------------------

; ============================================================
; basic - the vector x8024 comes here (power-up with no card, the DOS's
; BASIC command, BOOT.CFG "BASIC")
; ============================================================
w_ENDS_Q_:
    #d8 12, 40, 14, 1, 58, 37, 30, 0
load_t0:
    ld   (DOS_BUF & 0xFF) + 16, ac    ; the 496 bytes after the header
    ld   ac, [R0]
    ld   DOS_BUF >> 8, ac
    ld   ac, [R1]
    ld   [l_ll], ac
    ld   ac, [R2]
    ld   [l_lh], ac
    ld   ac, [R3]
    clr  ac
    ld   ac, [R4]
    ld   LINK_LO, x             ; CALL memcpy
    ld   rom_r22, [x]
    ld   LINK_HI, x
    ld   rom_r22 >> 8, [x]
    ld   memcpy >> 8, y
    jmp  memcpy
rom_r22:
    ld   240, ac
    ld   ac, [R4]
    ld   LINK_LO, x             ; CALL memcpy
    ld   rom_r23, [x]
    ld   LINK_HI, x
    ld   rom_r23 >> 8, [x]
    ld   memcpy >> 8, y
    jmp  memcpy
rom_r23:
    ld   [R2], ac               ; the rest straight to load + 496 on
    ld   ac, [R4]
    ld   [R3], ac
    ld   ac, [R5]
lt0_rd:
    ld   LINK_LO, x             ; CALL fs_read
    ld   rom_r24, [x]
    ld   LINK_HI, x
    ld   rom_r24 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
rom_r24:
    beq  lt0_rd
    xor  1, ac                  ; 1: the end
    bne  lt0_err
    ld   LINK_LO, x             ; a program over x1F00 is fine
    ld   rom_r25, [x]
    ld   LINK_HI, x
    ld   rom_r25 >> 8, [x]
    ld   lib_ram_copy >> 8, y
    jmp  lib_ram_copy
rom_r25:
    ld   [l_dos], ac
    bne  lt0_dos
    ld   LINK_LO, x             ; the folder it came from
    ld   rom_r26, [x]
    ld   LINK_HI, x
    ld   rom_r26 >> 8, [x]
    ld   save_dclus >> 8, y
    jmp  save_dclus
rom_r26:
    bra  lt0_go
lt0_dos:
    ld   LINK_LO, x             ; DOS.PLC: the folder the DOS was in
    ld   rom_r27, [x]
    ld   LINK_HI, x
    ld   rom_r27 >> 8, [x]
    ld   get_dclus >> 8, y
    jmp  get_dclus
rom_r27:
lt0_go:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   [l_eh], y
    jmp  [l_el]
lt0_err:
    xor  1, ac
    ld   fail >> 8, y
    jmp  fail

        ; page 0 last, then map FF and x0000 through MB_GO
load_t1:
    ld   LINK_LO, x             ; CALL save_dclus
    ld   rom_r28, [x]
    ld   LINK_HI, x
    ld   rom_r28 >> 8, [x]
    ld   save_dclus >> 8, y
    jmp  save_dclus
rom_r28:
    ld   1, ac
    ld   ac, [l_t]
lt1_z:
    ld   [l_t], y
    clr  ac
lt1_z2:
    ld   ac, x
    ld   0, [y,x]
    inc
    bne  lt1_z2
    ld   [l_t], ac
    inc
    ld   ac, [l_t]
    xor  0x4A, ac
    bne  lt1_z
    ld   (DOS_BUF & 0xFF) + 16, ac    ; page 0 of the image waits in DOS_BUF0
    ld   ac, [R0]
    ld   DOS_BUF >> 8, ac
    ld   ac, [R1]
    clr  ac
    ld   ac, [R2]
    ld   ac, [R4]
    ld   DOS_BUF0 >> 8, ac
    ld   ac, [R3]
    ld   LINK_LO, x             ; CALL memcpy
    ld   rom_r29, [x]
    ld   LINK_HI, x
    ld   rom_r29 >> 8, [x]
    ld   memcpy >> 8, y
    jmp  memcpy
rom_r29:
    clr  ac                     ; x0100-x01EF from the first sector
    ld   ac, [R2]
    ld   1, ac
    ld   ac, [R3]
    ld   240, ac
    ld   ac, [R4]
    ld   LINK_LO, x             ; CALL memcpy
    ld   rom_r30, [x]
    ld   LINK_HI, x
    ld   rom_r30 >> 8, [x]
    ld   memcpy >> 8, y
    jmp  memcpy
rom_r30:
    ld   0xF0, ac               ; the rest to x01F0 on
    ld   ac, [R4]
    ld   1, ac
    ld   ac, [R5]
lt1_rd:
    ld   LINK_LO, x             ; CALL fs_read
    ld   rom_r31, [x]
    ld   LINK_HI, x
    ld   rom_r31 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
rom_r31:
    beq  lt1_rd
    xor  1, ac
    bne  lt1_err
    ld   lt1_go >> 8, y
    jmp  lt1_go
lt1_err:
    xor  1, ac
    ld   fail >> 8, y
    jmp  fail

w_LINE_:
    #d8 w_NEXPR >> 8, w_NEXPR & 0xFF, 2, 150, 93, 24, w_COMMA >> 8, w_COMMA & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, 2, 152
    #d8 93, 24, w_COMMA >> 8, w_COMMA & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, 2, 164, 93, 24, w_COMMA >> 8, w_COMMA & 0xFF
    #d8 w_NEXPR >> 8, w_NEXPR & 0xFF, 2, 166, 93, 24, w_COMMA >> 8, w_COMMA & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, 2, 168
    #d8 93, 24, 2, 164, 93, 23, 2, 150, 93, 23, 28, 12
    #d8 w_ABS >> 8, w_ABS & 0xFF, 2, 154, 93, 24, w_SGN1 >> 8, w_SGN1 & 0xFF, 2, 158, 93, 24
    #d8 2, 166, 93, 23, 2, 152, 93, 23, 28, 12, w_ABS >> 8, w_ABS & 0xFF
    #d8 w_NEGATE >> 8, w_NEGATE & 0xFF, 2, 156, 93, 24, w_SGN1 >> 8, w_SGN1 & 0xFF, 2, 160, 93, 24
    #d8 2, 154, 93, 23, 2, 156, 93, 23, 27, 2, 162, 93
    #d8 24, 2, 150, 93, 23, 2, 152, 93, 23, 2, 168, 93
    #d8 23, w_PSET >> 8, w_PSET & 0xFF, 2, 150, 93, 23, 2, 164, 93, 23, 37
    #d8 2, 152, 93, 23, 2, 166, 93, 23, 37, 29, 4, 1
    #d8 0, 2, 162, 93, 23, 35, 12, 2, 156, 93, 23, 39
    #d8 40, 4, 18, 2, 156, 93, 23, 2, 162, 93, w__P__ST_ >> 8, w__P__ST_ & 0xFF
    #d8 2, 158, 93, 23, 2, 150, 93, w__P__ST_ >> 8, w__P__ST_ & 0xFF, 2, 154, 93
    #d8 23, w__GT_ >> 8, w__GT_ & 0xFF, 40, 4, 18, 2, 154, 93, 23, 2, 162
    #d8 93, w__P__ST_ >> 8, w__P__ST_ & 0xFF, 2, 160, 93, 23, 2, 152, 93, w__P__ST_ >> 8, w__P__ST_ & 0xFF
    #d8 3, 159, 0
w_GC:
    #d8 2, 0, 30, 2, 140, 93, 24, 2, 0, 30, 2, 142
    #d8 93, 24, 8, 60, 2, 140, 93, 23, 38, 4, 97, 2
    #d8 140, 93, 23, 1, 3, 28, 25, 1, 4, 27, 2, 144
    #d8 93, 24, 2, 140, 93, 23, 2, 144, 93, 23, 28, 2
    #d8 146, 93, 24, 2, 140, 93, 23, 1, 2, 28, 23, w__Q_DUP >> 8
    #d8 w__Q_DUP & 0xFF, 4, 47, 12, 23, 2, 146, 93, 23, 37, 4, 37
    #d8 2, 142, 93, 23, 2, 144, 93, 23, 28, 12, 17, 24
    #d8 2, 146, 93, 23, 14, 2, 144, 93, 23, 46, 2, 142
    #d8 93, 23, 2, 144, 93, 23, 28, 2, 142, 93, 24, 3
    #d8 1, 13, 2, 146, 93, 23, 2, 140, 93, 24, 3, 150
    #d8 2, 142, 93, 23, 9, 60, 0
w_MODE_:
    #d8 w_NEXPR >> 8, w_NEXPR & 0xFF, w_LOG2 >> 8, w_LOG2 & 0xFF, 11, 78, w_COMMA >> 8, w_COMMA & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, w_LOG2 >> 8, w_LOG2 & 0xFF
    #d8 12, 1, 3, 37, 4, 2, w_ILLQ >> 8, w_ILLQ & 0xFF, 11, 79, 49, 1
    #d8 44, 37, 4, 5, 51, w_NEXPR >> 8, w_NEXPR & 0xFF, 3, 2, 1, 0, 12
    #d8 2, 126, 93, 25, 38, 40, 15, 2, 126, 93, 25, 37
    #d8 40, 29, 4, 2, w_ILLQ >> 8, w_ILLQ & 0xFF, 12, 10, 51, 29, 4, 22
    #d8 10, 79, 40, 4, 2, w_LAYERR >> 8, w_LAYERR & 0xFF, 10, 79, 1, 2, 37
    #d8 15, 1, 6, w__GT_ >> 8, w__GT_ & 0xFF, 29, 4, 2, w_LAYERR >> 8, w_LAYERR & 0xFF, 12, 11
    #d8 50, 10, 51, 4, 4, 1, 16, 3, 2, 1, 8, 42
    #d8 9, 76, w_SETSCREEN >> 8, w_SETSCREEN & 0xFF, 0
w_DIR_:
    #d8 w_CARD >> 8, w_CARD & 0xFF, 1, 0, 2, (fs_cwd) & 0xFF, (fs_cwd) >> 8, w_FCALL >> 8, w_FCALL & 0xFF, 1, 0, 2
    #d8 (fs_next) & 0xFF, (fs_next) >> 8, 48, 12, 40, 4, 64, 13, 2, (FS_ENTRY) & 0xFF, (FS_ENTRY) >> 8, 25
    #d8 1, 46, 37, 40, 4, 51, 2, (FS_ENTRY) & 0xFF, (FS_ENTRY) >> 8, 1, 8, w_TYPEN >> 8
    #d8 w_TYPEN & 0xFF, 2, (FS_ENTRY + 8) & 0xFF, (FS_ENTRY + 8) >> 8, 25, 1, 32, 37, 40, 4, 11, 1
    #d8 46, w_EMIT >> 8, w_EMIT & 0xFF, 2, (FS_ENTRY + 8) & 0xFF, (FS_ENTRY + 8) >> 8, 1, 3, w_TYPEN >> 8, w_TYPEN & 0xFF, 2, (FS_ENTRY + 11) & 0xFF
    #d8 (FS_ENTRY + 11) >> 8, 25, 1, 16, 29, 4, 4, 1, 47, w_EMIT >> 8, w_EMIT & 0xFF, w_SPACE >> 8
    #d8 w_SPACE & 0xFF, 10, 13, 1, 15, 29, 40, 4, 246, 3, 182, 10
    #d8 13, 4, 2, w_CR >> 8, w_CR & 0xFF, 12, 1, 1, 37, 4, 3, 13
    #d8 3, 2, w_FERR >> 8, w_FERR & 0xFF, 0
w_SCOMPARE:
    #d8 w_COUNT >> 8, w_COUNT & 0xFF, 2, 138, 93, 24, 2, 136, 93, 24, w_COUNT >> 8, w_COUNT & 0xFF
    #d8 2, 134, 93, 24, 2, 132, 93, 24, 2, 134, 93, 23
    #d8 40, 4, 13, 2, 138, 93, 23, 4, 4, 1, 1, 3
    #d8 2, 1, 2, 0, 2, 138, 93, 23, 40, 4, 3, 1
    #d8 4, 0, 2, 132, 93, 23, 25, 2, 136, 93, 23, 25
    #d8 18, 37, 40, 4, 10, 38, 4, 4, 1, 1, 3, 2
    #d8 1, 4, 0, w_2DROP >> 8, w_2DROP & 0xFF, 2, 132, 93, w_1_P__ST_ >> 8, w_1_P__ST_ & 0xFF, 2, 136
    #d8 93, w_1_P__ST_ >> 8, w_1_P__ST_ & 0xFF, 2, 134, 93, w_1_M__ST_ >> 8, w_1_M__ST_ & 0xFF, 2, 138, 93, w_1_M__ST_ >> 8
    #d8 w_1_M__ST_ & 0xFF, 3, 177, 0
w_ERROR:
    #d8 2, (w_SCREMIT) & 0xFF, (w_SCREMIT) >> 8, 2, 120, 93, 24, w_TEXTBACK >> 8, w_TEXTBACK & 0xFF, 10, 13, 4
    #d8 2, w_CR >> 8, w_CR & 0xFF, 12, 1, 14, 37, 4, 11, 7, 5, 66
    #d8 114, 101, 97, 107, w_TYPE >> 8, w_TYPE & 0xFF, 3, 19, 1, 63, w_EMIT >> 8, w_EMIT & 0xFF
    #d8 12, w_ERRMSG >> 8, w_ERRMSG & 0xFF, w_TYPE >> 8, w_TYPE & 0xFF, 7, 6, 32, 101, 114, 114, 111
    #d8 114, w_TYPE >> 8, w_TYPE & 0xFF, 12, 1, 17, 37, 4, 8, w_SPACE >> 8, w_SPACE & 0xFF, 2
    #d8 128, 93, 23, w_U_D_ >> 8, w_U_D_ & 0xFF, 1, 14, 37, 40, 4, 4, 1
    #d8 0, 9, 72, 8, 54, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 12, 7, 4, 32
    #d8 105, 110, 32, w_TYPE >> 8, w_TYPE & 0xFF, w_LNUM >> 8, w_LNUM & 0xFF, w_U_D_ >> 8, w_U_D_ & 0xFF, w_CR >> 8, w_CR & 0xFF, w_WARM >> 8
    #d8 w_WARM & 0xFF, 0
w_ATOM:
    #d8 1, 0, 11, 66, 49, 12, 57, 4, 3, 13, 50, 0
    #d8 12, 1, 38, 37, 4, 5, 13, 51, w_HEXNUM >> 8, w_HEXNUM & 0xFF, 0, 12
    #d8 1, 34, 37, 4, 4, 13, w_STRLIT >> 8, w_STRLIT & 0xFF, 0, 12, 1, 40
    #d8 37, 4, 9, 13, 51, w_EXPR >> 8, w_EXPR & 0xFF, 1, 41, w_EXPECT >> 8, w_EXPECT & 0xFF, 0
    #d8 12, 58, 4, 20, 13, w_VARREF >> 8, w_VARREF & 0xFF, 10, 66, 4, 11, 23
    #d8 w__Q_DUP >> 8, w__Q_DUP & 0xFF, 40, 4, 3, 2, (w_EMPTYS) & 0xFF, (w_EMPTYS) >> 8, 3, 1, 23, 0
    #d8 12, 1, 177, 1, 193, w_WITHIN >> 8, w_WITHIN & 0xFF, 4, 12, 51, 1, 177
    #d8 28, 35, 2, (w_FNTAB) & 0xFF, (w_FNTAB) >> 8, 27, 23, 44, 0, w_SYNERR >> 8, w_SYNERR & 0xFF, 0
w_NEXT_:
    #d8 49, 58, 4, 4, w_VARREF >> 8, w_VARREF & 0xFF, 3, 2, 1, 0, w_FINDFOR >> 8, w_FINDFOR & 0xFF
    #d8 12, 1, 2, 27, 23, 12, 23, 1, 2, w_PICK >> 8, w_PICK & 0xFF, 1
    #d8 6, 27, 23, 27, w_TUCK >> 8, w_TUCK & 0xFF, 14, 24, 15, 1, 6, 27
    #d8 23, 41, 4, 8, 15, 1, 4, 27, 23, 39, 3, 7
    #d8 15, 1, 4, 27, 23, w__GT_ >> 8, w__GT_ & 0xFF, 4, 17, 1, 12, 27
    #d8 9, 64, 49, 1, 44, 37, 4, 3, 51, 3, 1, 0
    #d8 3, 18, 12, 1, 8, 27, 23, 9, 48, 1, 10, 27
    #d8 23, 9, 54, 1, 1, 11, 67, 0, 3, 162, 0
w_CRUNCH:
    #d8 2, 0, 84, 12, 9, 48, 2, 114, 93, 24, 8, 48
    #d8 25, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 70, 12, 1, 34, 37, 4, 5, 13
    #d8 w_CPYSTR >> 8, w_CPYSTR & 0xFF, 3, 57, 12, 1, 63, 37, 4, 8, 13, 51
    #d8 1, 145, w_PUTB >> 8, w_PUTB & 0xFF, 3, 43, w_UPC >> 8, w_UPC & 0xFF, 12, 58, w_PREVLET_Q_ >> 8, w_PREVLET_Q_ & 0xFF
    #d8 40, 29, 4, 30, w_KWMATCH >> 8, w_KWMATCH & 0xFF, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 19, 16, 12
    #d8 w_PUTB >> 8, w_PUTB & 0xFF, 12, 1, 142, 37, 14, 1, 131, 37, 30, 4
    #d8 2, w_CPYREST >> 8, w_CPYREST & 0xFF, 3, 3, w_PUTB >> 8, w_PUTB & 0xFF, 51, 3, 3, w_PUTB >> 8, w_PUTB & 0xFF
    #d8 51, 3, 179, 1, 0, w_PUTB >> 8, w_PUTB & 0xFF, 0
w_LOADFILE:
    #d8 w_FILENAME >> 8, w_FILENAME & 0xFF, 1, 0, 2, (fs_open) & 0xFF, (fs_open) >> 8, w_FCALL >> 8, w_FCALL & 0xFF, w_NEWPROG >> 8, w_NEWPROG & 0xFF, w_CLEARV >> 8
    #d8 w_CLEARV & 0xFF, 2, 0, 84, 2, 148, 93, 24, 2, (FS_REM + 2) & 0xFF, (FS_REM + 2) >> 8, 23
    #d8 4, 5, 2, 0, 2, 3, 9, 2, (FS_REM) & 0xFF, (FS_REM) >> 8, 23, 2
    #d8 0, 2, w_MIN >> 8, w_MIN & 0xFF, 2, 0, 86, 9, 20, 1, 0, 2
    #d8 (fs_read) & 0xFF, (fs_read) >> 8, 48, 12, 1, 1, 37, 4, 7, w_2DROP >> 8, w_2DROP & 0xFF, 1
    #d8 10, w_LOADBYTE >> 8, w_LOADBYTE & 0xFF, 0, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 2, w_FERR >> 8, w_FERR & 0xFF, 2, 0
    #d8 86, 14, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 10, 15, 25, w_LOADBYTE >> 8, w_LOADBYTE & 0xFF, 34, 14
    #d8 33, 14, 3, 242, 13, 3, 185, 0
w_INVARS:
    #d8 w_VARREF >> 8, w_VARREF & 0xFF, 10, 66, 19, w_INNEXT >> 8, w_INNEXT & 0xFF, 8, 48, 2, 116, 93
    #d8 24, 2, 118, 93, 23, 9, 48, 21, w_PFIELD >> 8, w_PFIELD & 0xFF, 8, 48
    #d8 2, 118, 93, 24, 2, 116, 93, 23, 9, 48, 40, 4
    #d8 17, w_2DROP >> 8, w_2DROP & 0xFF, 22, 7, 5, 63, 82, 101, 100, 111, w_TYPE >> 8
    #d8 w_TYPE & 0xFF, w_CR >> 8, w_CR & 0xFF, 1, 0, 0, 20, 4, 4, w_SASSIGN >> 8, w_SASSIGN & 0xFF, 3
    #d8 2, 14, 24, 2, 118, 93, 23, 25, 1, 44, 37, 4
    #d8 5, 2, 118, 93, w_1_P__ST_ >> 8, w_1_P__ST_ & 0xFF, 49, 1, 44, 37, 4, 3
    #d8 51, 3, 169, w_TRUE >> 8, w_TRUE & 0xFF, 0
w_FILENAME:
    #d8 w_SEXPR >> 8, w_SEXPR & 0xFF, w_CARD >> 8, w_CARD & 0xFF, w_COUNT >> 8, w_COUNT & 0xFF, 1, 11, w_MIN >> 8, w_MIN & 0xFF, 19, 2
    #d8 186, 93, 21, 45, 1, 0, 2, 186, 93, 21, 27, 26
    #d8 1, 0, 21, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 18, 34, 12, 2, 186, 93
    #d8 27, 25, 1, 46, 37, 4, 4, 16, w_TRUE >> 8, w_TRUE & 0xFF, 14, 3
    #d8 234, 40, 4, 28, 2, 186, 93, 21, 27, 7, 4, 46
    #d8 66, 65, 83, w_COUNT >> 8, w_COUNT & 0xFF, 19, 14, 20, 45, 1, 0, 2
    #d8 186, 93, 21, 27, 1, 4, 27, 26, 22, 2, 186, 93
    #d8 9, 16, 0
w_STMTAB:
    #d8 w_END_ & 0xFF, w_END_ >> 8, w_FOR_ & 0xFF, w_FOR_ >> 8, w_NEXT_ & 0xFF, w_NEXT_ >> 8, w_DATA_ & 0xFF, w_DATA_ >> 8, w_INPUT_ & 0xFF, w_INPUT_ >> 8, w_DIM_ & 0xFF, w_DIM_ >> 8
    #d8 w_READ_ & 0xFF, w_READ_ >> 8, w_LET_ & 0xFF, w_LET_ >> 8, w_GOTO_ & 0xFF, w_GOTO_ >> 8, w_RUN_ & 0xFF, w_RUN_ >> 8, w_IF_ & 0xFF, w_IF_ >> 8, w_RESTORE_ & 0xFF, w_RESTORE_ >> 8
    #d8 w_GOSUB_ & 0xFF, w_GOSUB_ >> 8, w_RETURN_ & 0xFF, w_RETURN_ >> 8, w_REM_ & 0xFF, w_REM_ >> 8, w_STOP_ & 0xFF, w_STOP_ >> 8, w_ON_ & 0xFF, w_ON_ >> 8, w_PRINT_ & 0xFF, w_PRINT_ >> 8
    #d8 w_LIST_ & 0xFF, w_LIST_ >> 8, w_CLEAR_ & 0xFF, w_CLEAR_ >> 8, w_NEW_ & 0xFF, w_NEW_ >> 8, w_CONT_ & 0xFF, w_CONT_ >> 8, w_POKE_ & 0xFF, w_POKE_ >> 8, w_CALL_ & 0xFF, w_CALL_ >> 8
    #d8 w_CLS_ & 0xFF, w_CLS_ >> 8, w_LOCATE_ & 0xFF, w_LOCATE_ >> 8, w_TINT_ & 0xFF, w_TINT_ >> 8, w_TEXT_ & 0xFF, w_TEXT_ >> 8, w_MODE_ & 0xFF, w_MODE_ >> 8, w_PLOT_ & 0xFF, w_PLOT_ >> 8
    #d8 w_LINE_ & 0xFF, w_LINE_ >> 8, w_SCAN_ & 0xFF, w_SCAN_ >> 8, w_BEEP_ & 0xFF, w_BEEP_ >> 8, w_SOUND_ & 0xFF, w_SOUND_ >> 8, w_NOISE_ & 0xFF, w_NOISE_ >> 8, w_WAIT_ & 0xFF, w_WAIT_ >> 8
    #d8 w_LOAD_ & 0xFF, w_LOAD_ >> 8, w_SAVE_ & 0xFF, w_SAVE_ >> 8, w_DIR_ & 0xFF, w_DIR_ >> 8, w_DEL_ & 0xFF, w_DEL_ >> 8, w_DOS_ & 0xFF, w_DOS_ >> 8, w_GET_ & 0xFF, w_GET_ >> 8
w_SAVE_:
    #d8 w_FILENAME >> 8, w_FILENAME & 0xFF, 1, 0, 2, (fs_create) & 0xFF, (fs_create) >> 8, w_FCALL >> 8, w_FCALL & 0xFF, 2, 0, 86
    #d8 2, 122, 93, 24, 1, 0, 2, 124, 93, 24, 2, (w_FEMIT) & 0xFF
    #d8 (w_FEMIT) >> 8, 2, 120, 93, 24, 2, 0, 32, 12, 25, 4, 8
    #d8 12, w_LISTLN >> 8, w_LISTLN & 0xFF, 12, 25, 27, 3, 244, 13, 2, (w_SCREMIT) & 0xFF, (w_SCREMIT) >> 8
    #d8 2, 120, 93, 24, 2, 122, 93, 23, 2, 0, 86, 37
    #d8 40, 4, 2, w_WRITESEC >> 8, w_WRITESEC & 0xFF, 2, 124, 93, 23, 9, 16, 1
    #d8 0, 9, 18, 1, 0, 2, (fs_close) & 0xFF, (fs_close) >> 8, w_FCALL >> 8, w_FCALL & 0xFF, 0
w_ACCEPT:
    #d8 1, 0, 1, 160, 54, w_KEY >> 8, w_KEY & 0xFF, 1, 32, 54, 12, 1
    #d8 10, 37, 4, 12, 13, 2, 0, 84, 27, 1, 0, 14
    #d8 26, w_CR >> 8, w_CR & 0xFF, 0, 12, 1, 8, 37, 4, 9, 13, 12
    #d8 4, 3, 34, w_BACK >> 8, w_BACK & 0xFF, 3, 32, 12, 1, 32, 1, 127
    #d8 w_WITHIN >> 8, w_WITHIN & 0xFF, 40, 4, 3, 13, 3, 19, 15, 1, 158, 39
    #d8 4, 12, 12, w_EMIT >> 8, w_EMIT & 0xFF, 15, 2, 0, 84, 27, 26, 33
    #d8 3, 1, 13, 3, 181, 0
w_LOADBYTE:
    #d8 12, 1, 10, 37, 4, 30, 13, 1, 0, 2, 148, 93
    #d8 23, 26, w_CRUNCH >> 8, w_CRUNCH & 0xFF, 2, 0, 84, 9, 48, 49, 57, 4
    #d8 3, 50, w_STORELN >> 8, w_STORELN & 0xFF, 2, 0, 84, 2, 148, 93, 24, 0
    #d8 12, 1, 13, 37, 4, 2, 13, 0, 2, 148, 93, 23
    #d8 2, 0, 84, 1, 250, 27, 38, 4, 12, 2, 148, 93
    #d8 23, 26, 2, 148, 93, w_1_P__ST_ >> 8, w_1_P__ST_ & 0xFF, 3, 1, 13, 0
w_MULX:
    #d8 w_UNARY >> 8, w_UNARY & 0xFF, 49, 12, 1, 42, 37, 4, 13, 13, 51, w_NUMCHK >> 8
    #d8 w_NUMCHK & 0xFF, w_UNARY >> 8, w_UNARY & 0xFF, w_NUMCHK >> 8, w_NUMCHK & 0xFF, 42, 1, 0, 3, 42, 12, 1
    #d8 47, 37, 4, 15, 13, 51, w_NUMCHK >> 8, w_NUMCHK & 0xFF, w_UNARY >> 8, w_UNARY & 0xFF, w_NUMCHK >> 8, w_NUMCHK & 0xFF
    #d8 w_SDIVMOD >> 8, w_SDIVMOD & 0xFF, 16, 1, 0, 3, 21, 1, 176, 37, 4, 14
    #d8 51, w_NUMCHK >> 8, w_NUMCHK & 0xFF, w_UNARY >> 8, w_UNARY & 0xFF, w_NUMCHK >> 8, w_NUMCHK & 0xFF, w_SDIVMOD >> 8, w_SDIVMOD & 0xFF, 13, 1, 0
    #d8 3, 2, w_TRUE >> 8, w_TRUE & 0xFF, 4, 192, 0
w_TINT_:
    #d8 w_NEXPR >> 8, w_NEXPR & 0xFF, w_COMMA >> 8, w_COMMA & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, 1, 7, 29, 35, 35, 35
    #d8 35, 14, 12, 10, 50, 38, 40, 4, 2, w_ILLQ >> 8, w_ILLQ & 0xFF, 10
    #d8 51, 4, 4, 1, 16, 3, 2, 1, 8, 12, 19, 42
    #d8 2, 32, 90, 27, 20, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 18, 19, 12, 25
    #d8 1, 143, 29, 1, 2, w_PICK >> 8, w_PICK & 0xFF, 30, 15, 26, 33, 20
    #d8 34, 3, 234, w_2DROP >> 8, w_2DROP & 0xFF, 0
w_COLD:
    #d8 2, (w_SCREMIT) & 0xFF, (w_SCREMIT) >> 8, 2, 120, 93, 24, 1, 0, 11, 78, 1
    #d8 0, 11, 79, 1, 60, w_TEXTSET >> 8, w_TEXTSET & 0xFF, w_NEWPROG >> 8, w_NEWPROG & 0xFF, w_CLEARV >> 8, w_CLEARV & 0xFF, 7
    #d8 13, 80, 76, 65, 67, 65, 82, 68, 32, 66, 65, 83
    #d8 73, 67, w_TYPE >> 8, w_TYPE & 0xFF, w_CR >> 8, w_CR & 0xFF, w_FREE >> 8, w_FREE & 0xFF, w_U_D_ >> 8, w_U_D_ & 0xFF, 7, 11
    #d8 32, 98, 121, 116, 101, 115, 32, 102, 114, 101, 101, w_TYPE >> 8
    #d8 w_TYPE & 0xFF, w_CR >> 8, w_CR & 0xFF, w_WARM >> 8, w_WARM & 0xFF, 0
w_LIST_:
    #d8 1, 0, 2, 255, 255, 49, 57, 4, 4, w_2DROP >> 8, w_2DROP & 0xFF, 50
    #d8 12, 49, 1, 45, 37, 4, 12, 51, 13, 49, 57, 4
    #d8 3, 50, 3, 3, 2, 255, 255, 14, w_FINDLN >> 8, w_FINDLN & 0xFF, 12, 25
    #d8 4, 7, 18, w_LNUM >> 8, w_LNUM & 0xFF, 38, 40, 3, 2, 1, 0, 4
    #d8 13, 52, 4, 2, w_WARM >> 8, w_WARM & 0xFF, 12, w_LISTLN >> 8, w_LISTLN & 0xFF, 12, 25, 27
    #d8 3, 228, w_2DROP >> 8, w_2DROP & 0xFF, 0
w_PRINT_:
    #d8 49, w_ENDS_Q_ >> 8, w_ENDS_Q_ & 0xFF, 4, 3, w_CR >> 8, w_CR & 0xFF, 0, 49, 1, 59, 37
    #d8 49, 1, 44, 37, 30, 4, 17, 49, 1, 44, 37, 4
    #d8 2, w_ZONE >> 8, w_ZONE & 0xFF, 51, 49, w_ENDS_Q_ >> 8, w_ENDS_Q_ & 0xFF, 4, 1, 0, 3, 25
    #d8 49, 1, 193, 37, 4, 7, 51, w_NARG >> 8, w_NARG & 0xFF, w_TABTO >> 8, w_TABTO & 0xFF, 3
    #d8 12, w_EXPR >> 8, w_EXPR & 0xFF, 10, 66, 4, 4, w_TYPE >> 8, w_TYPE & 0xFF, 3, 2, w_N_D_ >> 8
    #d8 w_N_D_ & 0xFF, 3, 193, 0
w_PSET:
    #d8 19, 12, w_GH >> 8, w_GH & 0xFF, 38, 40, 4, 4, w_2DROP >> 8, w_2DROP & 0xFF, 22, 0
    #d8 15, w_GW >> 8, w_GW & 0xFF, 38, 40, 4, 4, w_2DROP >> 8, w_2DROP & 0xFF, 22, 0, 10
    #d8 79, w_LSHIFT >> 8, w_LSHIFT & 0xFF, 8, 76, 27, 14, 12, 1, 3, 10, 78
    #d8 28, w_RSHIFT >> 8, w_RSHIFT & 0xFF, 17, 17, w_PPBM >> 8, w_PPBM & 0xFF, 29, 10, 78, w_LSHIFT >> 8, w_LSHIFT & 0xFF
    #d8 w_BPPM >> 8, w_BPPM & 0xFF, 15, w_LSHIFT >> 8, w_LSHIFT & 0xFF, 20, w_BPPM >> 8, w_BPPM & 0xFF, 29, 17, w_LSHIFT >> 8, w_LSHIFT & 0xFF
    #d8 56, 0
w_FOR_:
    #d8 w_VARREF >> 8, w_VARREF & 0xFF, 10, 66, 4, 2, w_TMERR >> 8, w_TMERR & 0xFF, 1, 61, w_EXPECT >> 8, w_EXPECT & 0xFF
    #d8 w_NEXPR >> 8, w_NEXPR & 0xFF, 15, 24, 1, 170, w_EXPECT >> 8, w_EXPECT & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, 49, 1
    #d8 171, 37, 4, 5, 51, w_NEXPR >> 8, w_NEXPR & 0xFF, 3, 2, 1, 1, 1
    #d8 2, w_PICK >> 8, w_PICK & 0xFF, w_FORPURGE >> 8, w_FORPURGE & 0xFF, 8, 54, w_CPUSH >> 8, w_CPUSH & 0xFF, 8, 48, w_CPUSH >> 8
    #d8 w_CPUSH & 0xFF, w_CPUSH >> 8, w_CPUSH & 0xFF, w_CPUSH >> 8, w_CPUSH & 0xFF, w_CPUSH >> 8, w_CPUSH & 0xFF, 1, 2, w_CPUSH >> 8, w_CPUSH & 0xFF, 0
w_ADDX:
    #d8 w_MULX >> 8, w_MULX & 0xFF, 49, 12, 1, 43, 37, 4, 28, 13, 51, 10
    #d8 66, 19, w_MULX >> 8, w_MULX & 0xFF, 10, 66, 21, w__LT__GT_ >> 8, w__LT__GT_ & 0xFF, 4, 2, w_TMERR >> 8
    #d8 w_TMERR & 0xFF, 20, 4, 4, w_CONCAT >> 8, w_CONCAT & 0xFF, 3, 1, 27, 1, 0, 3
    #d8 19, 1, 45, 37, 4, 12, 51, w_NUMCHK >> 8, w_NUMCHK & 0xFF, w_MULX >> 8, w_MULX & 0xFF, w_NUMCHK >> 8
    #d8 w_NUMCHK & 0xFF, 28, 1, 0, 3, 2, w_TRUE >> 8, w_TRUE & 0xFF, 4, 200, 0
w_ON_:
    #d8 w_NEXPR >> 8, w_NEXPR & 0xFF, 49, 12, 1, 136, 37, 14, 1, 140, 37, 30
    #d8 40, 4, 2, w_SYNERR >> 8, w_SYNERR & 0xFF, 49, 19, 51, 34, 12, 4, 17
    #d8 w_LINENO >> 8, w_LINENO & 0xFF, 13, 49, 1, 44, 37, 4, 3, 51, 3, 3
    #d8 13, 22, 0, 3, 235, 13, w_LINENO >> 8, w_LINENO & 0xFF, 20, 1, 140, 37
    #d8 4, 4, w_DOGOSUB >> 8, w_DOGOSUB & 0xFF, 3, 2, w_GOLN >> 8, w_GOLN & 0xFF, 0
w_PFIELD:
    #d8 4, 39, 49, 1, 34, 37, 4, 4, w_STRLIT >> 8, w_STRLIT & 0xFF, 3, 25
    #d8 8, 48, 8, 48, 25, 12, 1, 44, 37, 14, w_ENDS_Q_ >> 8, w_ENDS_Q_ & 0xFF
    #d8 30, 40, 4, 3, 51, 3, 239, 8, 48, 15, 28, w_MKSTR >> 8
    #d8 w_MKSTR & 0xFF, w_TRUE >> 8, w_TRUE & 0xFF, 3, 2, w_SNUMOK >> 8, w_SNUMOK & 0xFF, 49, 12, 1, 44, 37
    #d8 14, w_ENDS_Q_ >> 8, w_ENDS_Q_ & 0xFF, 30, 29, 0
w_FINDFOR:
    #d8 8, 64, 2, 0, 31, 37, 4, 2, w_NFERR >> 8, w_NFERR & 0xFF, 8, 64
    #d8 23, 1, 2, 37, 40, 4, 2, w_NFERR >> 8, w_NFERR & 0xFF, 12, 40, 4
    #d8 4, 13, 8, 64, 0, 12, 8, 64, 1, 2, 27, 23
    #d8 37, 4, 4, 13, 8, 64, 0, 8, 64, 1, 12, 27
    #d8 9, 64, 3, 204, 0
w_INPUT_:
    #d8 8, 54, 40, 4, 2, w_IDERR >> 8, w_IDERR & 0xFF, 49, 1, 34, 37, 4
    #d8 16, w_STRLIT >> 8, w_STRLIT & 0xFF, w_TYPE >> 8, w_TYPE & 0xFF, 49, 1, 59, 37, 49, 1, 44
    #d8 37, 30, 4, 1, 51, 8, 48, 2, 130, 93, 24, 2
    #d8 130, 93, 23, 9, 48, 1, 0, 2, 118, 93, 24, w_INVARS >> 8
    #d8 w_INVARS & 0xFF, 4, 240, 0
w_READ_:
    #d8 w_VARREF >> 8, w_VARREF & 0xFF, 10, 66, 19, 8, 48, 2, 116, 93, 24, w_DFIND >> 8
    #d8 w_DFIND & 0xFF, 21, w_PFIELD >> 8, w_PFIELD & 0xFF, 8, 48, 9, 70, 2, 116, 93, 23
    #d8 9, 48, 40, 4, 2, w_SYNERR >> 8, w_SYNERR & 0xFF, 20, 4, 4, w_SASSIGN >> 8, w_SASSIGN & 0xFF
    #d8 3, 2, 14, 24, 49, 1, 44, 37, 4, 3, 51, 3
    #d8 207, 0
w_SNUMOK:
    #d8 49, 1, 45, 37, 4, 5, 51, w_TRUE >> 8, w_TRUE & 0xFF, 3, 2, 1
    #d8 0, 19, 49, 57, 4, 5, 50, w_TRUE >> 8, w_TRUE & 0xFF, 3, 17, 49
    #d8 1, 38, 37, 4, 7, 51, w_HEXNUM >> 8, w_HEXNUM & 0xFF, w_TRUE >> 8, w_TRUE & 0xFF, 3, 4
    #d8 1, 0, 1, 0, 14, 20, 4, 2, w_NEGATE >> 8, w_NEGATE & 0xFF, 14, 0
w_RELOP:
    #d8 1, 0, 49, 12, 1, 60, 37, 4, 5, 13, 1, 1
    #d8 3, 22, 12, 1, 61, 37, 4, 5, 13, 1, 2, 3
    #d8 11, 1, 62, 37, 4, 4, 1, 4, 3, 2, 1, 0
    #d8 w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 4, 30, 51, 3, 214, 0
w_STATEMENT:
    #d8 49, 12, 1, 128, 39, 4, 15, 12, 58, 4, 4, 13
    #d8 w_LET_ >> 8, w_LET_ & 0xFF, 0, w_ENDS_Q_ >> 8, w_ENDS_Q_ & 0xFF, 4, 1, 0, w_SYNERR >> 8, w_SYNERR & 0xFF, 1, 128
    #d8 28, 12, 1, 42, 38, 40, 4, 2, w_SYNERR >> 8, w_SYNERR & 0xFF, 51, 35
    #d8 2, (w_STMTAB) & 0xFF, (w_STMTAB) >> 8, 27, 23, 44, 0
w_FORPURGE:
    #d8 8, 64, 12, 2, 0, 31, 38, 4, 7, 12, 23, 1
    #d8 2, 37, 3, 2, 1, 0, 4, 20, 18, 1, 2, 27
    #d8 23, 37, 4, 7, 1, 12, 27, 9, 64, 13, 0, 1
    #d8 12, 27, 3, 218, w_2DROP >> 8, w_2DROP & 0xFF, 0
w_INNEXT:
    #d8 2, 118, 93, 23, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 3, 25, 3, 2, 1
    #d8 0, 40, 4, 25, 2, 118, 93, 23, 4, 4, 1, 63
    #d8 w_EMIT >> 8, w_EMIT & 0xFF, 7, 2, 63, 32, w_TYPE >> 8, w_TYPE & 0xFF, w_ACCEPT >> 8, w_ACCEPT & 0xFF, 2, 0
    #d8 84, 2, 118, 93, 24, 0
w_CMPX:
    #d8 w_ADDX >> 8, w_ADDX & 0xFF, w_RELOP >> 8, w_RELOP & 0xFF, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 32, 19, 10, 66, 19
    #d8 w_ADDX >> 8, w_ADDX & 0xFF, 10, 66, 21, w__LT__GT_ >> 8, w__LT__GT_ & 0xFF, 4, 2, w_TMERR >> 8, w_TMERR & 0xFF, 20
    #d8 4, 4, w_SCOMPARE >> 8, w_SCOMPARE & 0xFF, 3, 2, w_NCOMPARE >> 8, w_NCOMPARE & 0xFF, 20, 29, w_0_LT__GT_ >> 8, w_0_LT__GT_ & 0xFF
    #d8 1, 0, 11, 66, 0
w_EXECLINE:
    #d8 52, 4, 2, w_BREAK >> 8, w_BREAK & 0xFF, 2, 0, 88, 9, 62, 1, 0
    #d8 11, 67, w_STATEMENT >> 8, w_STATEMENT & 0xFF, 10, 67, 40, 4, 17, 49, 12, 1
    #d8 58, 37, 4, 4, 13, 51, 3, 6, 4, 2, w_SYNERR >> 8, w_SYNERR & 0xFF
    #d8 w_NEXTLN >> 8, w_NEXTLN & 0xFF, 3, 216, 0
w_DFIND:
    #d8 8, 70, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 12, 9, 48, 49, 1, 44, 37
    #d8 4, 2, 51, 0, 3, 20, 2, 0, 32, 25, 40, 4
    #d8 2, w_ODERR >> 8, w_ODERR & 0xFF, 2, 0, 32, 12, 9, 68, 1, 3, 27
    #d8 9, 48, w_DSCAN >> 8, w_DSCAN & 0xFF, 0
w_LOG2:
    #d8 12, 1, 1, 37, 4, 4, 13, 1, 0, 0, 12, 1
    #d8 2, 37, 4, 4, 13, 1, 1, 0, 12, 1, 4, 37
    #d8 4, 4, 13, 1, 2, 0, 1, 8, 37, 4, 3, 1
    #d8 3, 0, w_ILLQ >> 8, w_ILLQ & 0xFF, 0
w_SCAN_:
    #d8 w_NEXPR >> 8, w_NEXPR & 0xFF, w_COMMA >> 8, w_COMMA & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, w_COMMA >> 8, w_COMMA & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, 19, 12
    #d8 2, 224, 1, 38, 40, 4, 2, w_ILLQ >> 8, w_ILLQ & 0xFF, 15, 28, 33
    #d8 12, 1, 1, 39, 4, 2, w_ILLQ >> 8, w_ILLQ & 0xFF, 14, 2, 32, 90
    #d8 27, 14, 20, 47, 0
w_DSCAN:
    #d8 8, 48, 25, 12, 1, 131, 37, 4, 3, 13, 51, 0
    #d8 4, 3, 51, 3, 20, 8, 68, 12, 25, 27, 12, 25
    #d8 40, 4, 2, w_ODERR >> 8, w_ODERR & 0xFF, 12, 9, 68, 1, 3, 27, 9
    #d8 48, 3, 217, 0
w_ARRREF:
    #d8 51, w_NEXPR >> 8, w_NEXPR & 0xFF, 1, 41, w_EXPECT >> 8, w_EXPECT & 0xFF, 14, 12, 59, w__Q_DUP >> 8, w__Q_DUP & 0xFF
    #d8 40, 4, 7, 1, 10, 14, w_DIMARR >> 8, w_DIMARR & 0xFF, 3, 1, 16, 18
    #d8 1, 2, 28, 23, 36, 38, 40, 4, 2, w_BSERR >> 8, w_BSERR & 0xFF, 14
    #d8 35, 27, 0
w_KWCMP:
    #d8 8, 48, 15, 25, 15, 25, w_UPC >> 8, w_UPC & 0xFF, 15, 1, 127, 29
    #d8 37, 4, 17, 1, 128, 29, 4, 6, 16, 33, 8, 48
    #d8 28, 0, 33, 14, 33, 14, 3, 226, 13, w_2DROP >> 8, w_2DROP & 0xFF, 1
    #d8 0, 0
w_NEWVAR:
    #d8 12, 1, 4, 27, w_ROOM >> 8, w_ROOM & 0xFF, 8, 58, 19, 14, 21, 24
    #d8 12, 21, 1, 2, 27, 24, 21, 1, 4, 27, 15, 1
    #d8 0, 47, 1, 4, 27, 21, 27, 9, 58, 20, 1, 4
    #d8 27, 0
w_SOUND_:
    #d8 w_NEXPR >> 8, w_NEXPR & 0xFF, w_COMMA >> 8, w_COMMA & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, 49, 1, 44, 37, 4, 5
    #d8 51, w_NEXPR >> 8, w_NEXPR & 0xFF, 3, 2, 1, 96, 19, 11, 18, 1, 0
    #d8 11, 19, 2, (snd_note) & 0xFF, (snd_note) >> 8, 48, 13, 20, 2, (snd_tone) & 0xFF, (snd_tone) >> 8, 48
    #d8 13, 0
w_SKIPSTMT:
    #d8 1, 0, 8, 48, 25, 12, 40, 4, 3, w_2DROP >> 8, w_2DROP & 0xFF, 0
    #d8 12, 1, 34, 37, 4, 4, 13, 40, 3, 10, 1, 58
    #d8 37, 15, 40, 29, 4, 2, 13, 0, 51, 3, 223, 0
w_STORELN:
    #d8 1, 0, 9, 72, w_CLEARV >> 8, w_CLEARV & 0xFF, 12, w_FINDLN >> 8, w_FINDLN & 0xFF, 12, 25, 4
    #d8 13, 12, w_LNUM >> 8, w_LNUM & 0xFF, 1, 2, w_PICK >> 8, w_PICK & 0xFF, 37, 4, 3, 12
    #d8 w_DELLN >> 8, w_DELLN & 0xFF, 49, 4, 4, w_INSLN >> 8, w_INSLN & 0xFF, 3, 2, w_2DROP >> 8, w_2DROP & 0xFF, 0
w_VARREF:
    #d8 60, 12, 19, 12, 41, 4, 4, w_ARRREF >> 8, w_ARRREF & 0xFF, 3, 13, 12
    #d8 59, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 3, 16, 3, 4, 1, 2, w_NEWVAR >> 8, w_NEWVAR & 0xFF
    #d8 20, 1, 128, 29, w_0_LT__GT_ >> 8, w_0_LT__GT_ & 0xFF, 1, 1, 29, 11, 66, 0
w_CONCAT:
    #d8 15, 25, 15, 25, 27, 12, 1, 255, w__GT_ >> 8, w__GT_ & 0xFF, 4, 2
    #d8 w_STLERR >> 8, w_STLERR & 0xFF, w_TMPALLOC >> 8, w_TMPALLOC & 0xFF, 17, 18, w_COUNT >> 8, w_COUNT & 0xFF, 17, 33, 14, 45
    #d8 25, 15, 27, 33, 17, w_COUNT >> 8, w_COUNT & 0xFF, 19, 14, 20, 45, 0
w_STRLIT:
    #d8 51, 8, 48, 8, 48, 25, 12, 1, 34, 37, 14, 40
    #d8 30, 40, 4, 3, 51, 3, 240, 8, 48, 15, 28, w_MKSTR >> 8
    #d8 w_MKSTR & 0xFF, 8, 48, 25, 4, 1, 51, 1, 1, 11, 66, 0
w_LISTLN:
    #d8 12, w_LNUM >> 8, w_LNUM & 0xFF, w_U_D_ >> 8, w_U_D_ & 0xFF, w_SPACE >> 8, w_SPACE & 0xFF, 1, 3, 27, 12, 25
    #d8 w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 15, 12, 1, 128, 39, 4, 4, w_EMIT >> 8, w_EMIT & 0xFF
    #d8 3, 2, w_KWTYPE >> 8, w_KWTYPE & 0xFF, 33, 3, 235, 13, w_CR >> 8, w_CR & 0xFF, 0
w_CAPTURE:
    #d8 2, 120, 93, 23, 19, 2, (w_TMPEMIT) & 0xFF, (w_TMPEMIT) >> 8, 2, 120, 93, 24
    #d8 8, 62, 19, 1, 0, 8, 62, 26, 44, 21, 25, 33
    #d8 21, 27, 9, 62, 20, 20, 2, 120, 93, 24, 0
w_RETURN_:
    #d8 8, 64, 2, 0, 31, 37, 4, 2, w_RGERR >> 8, w_RGERR & 0xFF, w_CPOP >> 8, w_CPOP & 0xFF
    #d8 1, 1, 37, 4, 13, w_CPOP >> 8, w_CPOP & 0xFF, 9, 48, w_CPOP >> 8, w_CPOP & 0xFF, 9
    #d8 54, 1, 1, 11, 67, 0, w_FORDROP >> 8, w_FORDROP & 0xFF, 3, 222, 0
w_DIM_:
    #d8 60, 12, 41, 40, 4, 2, w_SYNERR >> 8, w_SYNERR & 0xFF, 51, w_NEXPR >> 8, w_NEXPR & 0xFF, 1
    #d8 41, w_EXPECT >> 8, w_EXPECT & 0xFF, 12, 41, 4, 2, w_ILLQ >> 8, w_ILLQ & 0xFF, 14, w_DIMARR >> 8, w_DIMARR & 0xFF
    #d8 13, 49, 1, 44, 37, 4, 3, 51, 3, 222, 0
w_SVAL:
    #d8 w_COUNT >> 8, w_COUNT & 0xFF, 1, 15, w_MIN >> 8, w_MIN & 0xFF, 19, 2, 170, 93, 21, 45
    #d8 1, 0, 2, 170, 93, 20, 27, 26, 8, 48, 19, 2
    #d8 170, 93, 9, 48, w_SNUM >> 8, w_SNUM & 0xFF, 20, 9, 48, 0
w_SUBSTR:
    #d8 19, 15, 25, w_MIN >> 8, w_MIN & 0xFF, 15, 25, 15, 28, 20, w_MIN >> 8, w_MIN & 0xFF
    #d8 1, 0, w_MAX >> 8, w_MAX & 0xFF, 12, w_TMPALLOC >> 8, w_TMPALLOC & 0xFF, 19, 17, 33, 17, 27
    #d8 21, 33, 17, 45, 20, 1, 1, 11, 66, 0
w_SETSCREEN:
    #d8 w_TMB >> 8, w_TMB & 0xFF, 2, (vid_clear) & 0xFF, (vid_clear) >> 8, 48, 13, 8, 76, 2, 224, 1
    #d8 39, 4, 15, 2, 32, 90, 8, 76, 27, 2, 224, 1
    #d8 8, 76, 28, w_GMB >> 8, w_GMB & 0xFF, 47, w_HOME >> 8, w_HOME & 0xFF, 0
w_SDIVMOD:
    #d8 12, 40, 4, 2, w_D0ERR >> 8, w_D0ERR & 0xFF, 18, 31, 19, 15, 19, w_ABS >> 8
    #d8 w_ABS & 0xFF, 14, w_ABS >> 8, w_ABS & 0xFF, 14, 43, 20, 41, 4, 4, 14, w_NEGATE >> 8
    #d8 w_NEGATE & 0xFF, 14, 20, 41, 4, 2, w_NEGATE >> 8, w_NEGATE & 0xFF, 0
w_SCREMIT:
    #d8 12, 1, 10, 37, 4, 4, 13, w_SCRCR >> 8, w_SCRCR & 0xFF, 0, 10, 50
    #d8 4, 3, 54, 3, 1, 13, 10, 13, 33, 12, 11, 13
    #d8 1, 80, 37, 4, 2, w_SCRCR >> 8, w_SCRCR & 0xFF, 0
w_SNUM:
    #d8 49, 1, 45, 37, 4, 6, 51, w_SNUM >> 8, w_SNUM & 0xFF, w_NEGATE >> 8, w_NEGATE & 0xFF, 0
    #d8 49, 1, 38, 37, 4, 4, 51, w_HEXNUM >> 8, w_HEXNUM & 0xFF, 0, 49, 57
    #d8 4, 3, 50, 3, 2, 1, 0, 0
w_FNTAB:
    #d8 w_F_ABS & 0xFF, w_F_ABS >> 8, w_F_RND & 0xFF, w_F_RND >> 8, w_F_PEEK & 0xFF, w_F_PEEK >> 8, w_F_SGN & 0xFF, w_F_SGN >> 8, w_F_FRE & 0xFF, w_F_FRE >> 8, w_F_INKEY & 0xFF, w_F_INKEY >> 8
    #d8 w_F_PAD & 0xFF, w_F_PAD >> 8, w_F_LEN & 0xFF, w_F_LEN >> 8, w_F_ASC & 0xFF, w_F_ASC >> 8, w_F_VAL & 0xFF, w_F_VAL >> 8, w_F_CHR & 0xFF, w_F_CHR >> 8, w_F_STR & 0xFF, w_F_STR >> 8
    #d8 w_F_LEFT & 0xFF, w_F_LEFT >> 8, w_F_MID & 0xFF, w_F_MID >> 8, w_F_RIGHT & 0xFF, w_F_RIGHT >> 8, w_F_HEX & 0xFF, w_F_HEX >> 8
w_IF_:
    #d8 w_NEXPR >> 8, w_NEXPR & 0xFF, 49, 1, 136, 37, 40, 4, 4, 1, 172, w_EXPECT >> 8
    #d8 w_EXPECT & 0xFF, 4, 14, 49, 57, 4, 4, w_GOTO_ >> 8, w_GOTO_ & 0xFF, 3, 4, 1
    #d8 1, 11, 67, 3, 2, w_SKIPLINE >> 8, w_SKIPLINE & 0xFF, 0
w_GET_:
    #d8 w_VARREF >> 8, w_VARREF & 0xFF, w_KEY_Q_ >> 8, w_KEY_Q_ & 0xFF, 10, 66, 4, 21, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 10
    #d8 1, 1, w_TMPALLOC >> 8, w_TMPALLOC & 0xFF, w_TUCK >> 8, w_TUCK & 0xFF, 33, 26, 3, 3, 2, (w_EMPTYS) & 0xFF
    #d8 (w_EMPTYS) >> 8, w_SASSIGN >> 8, w_SASSIGN & 0xFF, 3, 2, 14, 24, 0
w_F_MID:
    #d8 w_STRN >> 8, w_STRN & 0xFF, 12, 1, 1, 39, 4, 2, w_ILLQ >> 8, w_ILLQ & 0xFF, 34, 49
    #d8 1, 44, 37, 4, 5, 51, w_NEXPR >> 8, w_NEXPR & 0xFF, 3, 2, 1, 255
    #d8 1, 41, w_EXPECT >> 8, w_EXPECT & 0xFF, w_SUBSTR >> 8, w_SUBSTR & 0xFF, 0
w_WARM:
    #d8 53, 2, (w_SCREMIT) & 0xFF, (w_SCREMIT) >> 8, 2, 120, 93, 24, w_TEXTBACK >> 8, w_TEXTBACK & 0xFF, 10, 13
    #d8 4, 2, w_CR >> 8, w_CR & 0xFF, 7, 5, 82, 101, 97, 100, 121, w_TYPE >> 8
    #d8 w_TYPE & 0xFF, w_CR >> 8, w_CR & 0xFF, w_MAIN >> 8, w_MAIN & 0xFF, 0
w_MAIN:
    #d8 w_ACCEPT >> 8, w_ACCEPT & 0xFF, w_CRUNCH >> 8, w_CRUNCH & 0xFF, 2, 0, 84, 9, 48, 49, 57, 4
    #d8 5, 50, w_STORELN >> 8, w_STORELN & 0xFF, 3, 9, 49, 4, 6, 1, 0, 9
    #d8 54, w_EXECLINE >> 8, w_EXECLINE & 0xFF, 3, 227, 0
w_LET_:
    #d8 w_VARREF >> 8, w_VARREF & 0xFF, 10, 66, 19, 1, 61, w_EXPECT >> 8, w_EXPECT & 0xFF, w_EXPR >> 8, w_EXPR & 0xFF, 10
    #d8 66, 21, w__LT__GT_ >> 8, w__LT__GT_ & 0xFF, 4, 2, w_TMERR >> 8, w_TMERR & 0xFF, 20, 4, 4, w_SASSIGN >> 8
    #d8 w_SASSIGN & 0xFF, 3, 2, 14, 24, 0
w_HEXNUM:
    #d8 49, 1, 72, 37, 4, 1, 51, 1, 0, 8, 48, 25
    #d8 w_HEXDIG >> 8, w_HEXDIG & 0xFF, 12, 41, 40, 4, 8, 14, 1, 16, 42, 27
    #d8 51, 3, 238, 13, 0
w_LOCATE_:
    #d8 w_NEXPR >> 8, w_NEXPR & 0xFF, w_COMMA >> 8, w_COMMA & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, 12, 1, 80, 38, 40, 4
    #d8 2, w_ILLQ >> 8, w_ILLQ & 0xFF, 11, 13, 12, 10, 50, 38, 40, 4, 2
    #d8 w_ILLQ >> 8, w_ILLQ & 0xFF, 11, 14, 0
w_RUN_:
    #d8 49, 1, 34, 37, 4, 7, w_LOADFILE >> 8, w_LOADFILE & 0xFF, w_CLEARV >> 8, w_CLEARV & 0xFF, w_RUNSTART >> 8, w_RUNSTART & 0xFF
    #d8 0, w_CLEARV >> 8, w_CLEARV & 0xFF, 49, 57, 4, 6, w_LINENO >> 8, w_LINENO & 0xFF, w_GOLN >> 8, w_GOLN & 0xFF, 3
    #d8 2, w_RUNSTART >> 8, w_RUNSTART & 0xFF, 0
w_FPUT:
    #d8 2, 122, 93, 23, 26, 2, 122, 93, w_1_P__ST_ >> 8, w_1_P__ST_ & 0xFF, 2, 124
    #d8 93, w_1_P__ST_ >> 8, w_1_P__ST_ & 0xFF, 2, 122, 93, 23, 2, 0, 88, 37, 4
    #d8 2, w_WRITESEC >> 8, w_WRITESEC & 0xFF, 0
w_UNARY:
    #d8 49, 1, 45, 37, 4, 8, 51, w_UNARY >> 8, w_UNARY & 0xFF, w_NUMCHK >> 8, w_NUMCHK & 0xFF, w_NEGATE >> 8
    #d8 w_NEGATE & 0xFF, 0, 49, 1, 43, 37, 4, 4, 51, w_UNARY >> 8, w_UNARY & 0xFF, 0
    #d8 w_ATOM >> 8, w_ATOM & 0xFF, 0
w_SCRCR:
    #d8 1, 0, 11, 13, 10, 50, 40, 4, 1, 0, 10, 14
    #d8 33, 12, 10, 50, 38, 4, 3, 11, 14, 0, 13, w_SCROLL >> 8
    #d8 w_SCROLL & 0xFF, 0
w_FINDLN:
    #d8 19, 2, 0, 32, 12, 25, 4, 7, 12, w_LNUM >> 8, w_LNUM & 0xFF, 21
    #d8 38, 3, 2, 1, 0, 4, 5, 12, 25, 27, 3, 236
    #d8 22, 0
w_TYPEN:
    #d8 12, 4, 20, 15, 25, 12, 1, 32, 37, 4, 4, 13
    #d8 w_2DROP >> 8, w_2DROP & 0xFF, 0, w_EMIT >> 8, w_EMIT & 0xFF, 34, 14, 33, 14, 3, 233, w_2DROP >> 8
    #d8 w_2DROP & 0xFF, 0
w_TEXTSET:
    #d8 12, 1, 30, 37, 1, 1, 29, 11, 51, 12, 2, 126
    #d8 93, 26, 11, 50, 2, 224, 1, 9, 76, w_SETSCREEN >> 8, w_SETSCREEN & 0xFF, 0
w_BACK:
    #d8 10, 13, 4, 6, 10, 13, 34, 11, 13, 0, 10, 14
    #d8 4, 9, 10, 14, 34, 11, 14, 1, 79, 11, 13, 0
w_NOISE_:
    #d8 w_NEXPR >> 8, w_NEXPR & 0xFF, w_COMMA >> 8, w_COMMA & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, w_COMMA >> 8, w_COMMA & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, 11, 18
    #d8 11, 16, 1, 0, 11, 19, 2, (snd_noise) & 0xFF, (snd_noise) >> 8, 48, 13, 0
w_CLRROW:
    #d8 11, 14, 1, 0, 12, 11, 13, 1, 32, 54, 33, 12
    #d8 1, 80, 37, 4, 243, 13, 1, 0, 11, 13, 0
w_GOLN:
    #d8 12, w_FINDLN >> 8, w_FINDLN & 0xFF, 12, 25, 4, 12, w_TUCK >> 8, w_TUCK & 0xFF, w_LNUM >> 8, w_LNUM & 0xFF, 37
    #d8 4, 3, w_GOLINE >> 8, w_GOLINE & 0xFF, 0, 3, 1, 16, w_ULERR >> 8, w_ULERR & 0xFF, 0
w_TMPALLOC:
    #d8 8, 62, w_TUCK >> 8, w_TUCK & 0xFF, 26, 12, 25, 33, 15, 27, 12, 2
    #d8 0, 90, 38, 40, 4, 2, w_STLERR >> 8, w_STLERR & 0xFF, 9, 62, 0
w_NEXTLN:
    #d8 8, 54, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 40, 4, 2, w_WARM >> 8, w_WARM & 0xFF, 12, 25, 27
    #d8 12, 25, 40, 4, 2, w_WARM >> 8, w_WARM & 0xFF, w_GOLINE >> 8, w_GOLINE & 0xFF, 0
w_SCROLL:
    #d8 10, 50, 34, 1, 0, 18, w__GT_ >> 8, w__GT_ & 0xFF, 4, 7, 12, 33
    #d8 15, 55, 33, 3, 244, 13, w_CLRROW >> 8, w_CLRROW & 0xFF, 0
w_KWTYPE:
    #d8 w_KWADDR >> 8, w_KWADDR & 0xFF, 12, 25, 12, 1, 127, 29, w_EMIT >> 8, w_EMIT & 0xFF, 1, 128
    #d8 29, 40, 4, 3, 33, 3, 239, 13, 0
w_F_PAD:
    #d8 w_NARG >> 8, w_NARG & 0xFF, 1, 0, 2, (pad_read) & 0xFF, (pad_read) >> 8, 48, 13, 1, 1, 37
    #d8 4, 4, 8, 16, 3, 2, 8, 18, 0
w_CLEARV:
    #d8 2, 0, 1, 9, 58, 2, 0, 30, 9, 60, 2, 0
    #d8 31, 9, 64, 1, 0, 9, 70, 0
w_CONT_:
    #d8 8, 72, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 40, 4, 2, w_CCERR >> 8, w_CCERR & 0xFF, 9, 54, 8
    #d8 74, 9, 48, 1, 1, 11, 67, 0
w_WAIT_:
    #d8 w_NEXPR >> 8, w_NEXPR & 0xFF, 8, 8, 27, 52, 4, 2, w_BREAK >> 8, w_BREAK & 0xFF, 12, 8
    #d8 8, 28, 41, 40, 4, 243, 13, 0
w_WRITESEC:
    #d8 2, 0, 86, 9, 20, 1, 0, 2, (fs_write) & 0xFF, (fs_write) >> 8, w_FCALL >> 8, w_FCALL & 0xFF
    #d8 2, 0, 86, 2, 122, 93, 24, 0
w_KWADDR:
    #d8 1, 128, 28, 2, (w_KWTAB) & 0xFF, (w_KWTAB) >> 8, 14, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 7, 14
    #d8 w_KWSKIP >> 8, w_KWSKIP & 0xFF, 14, 34, 3, 245, 0
w_ROOM:
    #d8 12, w_FREE >> 8, w_FREE & 0xFF, 38, 4, 2, 13, 0, w_GC >> 8, w_GC & 0xFF, w_FREE >> 8, w_FREE & 0xFF
    #d8 38, 40, 4, 2, w_OOMERR >> 8, w_OOMERR & 0xFF, 0
w_CPUSH:
    #d8 8, 64, 1, 2, 28, 12, 2, 0, 30, 38, 4, 2
    #d8 w_OOMERR >> 8, w_OOMERR & 0xFF, 12, 9, 64, 24, 0
w_EXPR:
    #d8 w_ANDX >> 8, w_ANDX & 0xFF, 49, 1, 174, 37, 4, 10, 51, w_NUMCHK >> 8, w_NUMCHK & 0xFF, w_ANDX >> 8
    #d8 w_ANDX & 0xFF, w_NUMCHK >> 8, w_NUMCHK & 0xFF, 30, 3, 240, 0
w_ANDX:
    #d8 w_NOTX >> 8, w_NOTX & 0xFF, 49, 1, 173, 37, 4, 10, 51, w_NUMCHK >> 8, w_NUMCHK & 0xFF, w_NOTX >> 8
    #d8 w_NOTX & 0xFF, w_NUMCHK >> 8, w_NUMCHK & 0xFF, 29, 3, 240, 0
w_NCOMPARE:
    #d8 18, 37, 4, 5, w_2DROP >> 8, w_2DROP & 0xFF, 1, 2, 0, 39, 4, 4
    #d8 1, 1, 3, 2, 1, 4, 0
w_CALL_:
    #d8 w_NEXPR >> 8, w_NEXPR & 0xFF, 49, 1, 44, 37, 4, 5, 51, w_NEXPR >> 8, w_NEXPR & 0xFF, 3
    #d8 2, 1, 0, 14, 48, 13, 0
w_TEXT_:
    #d8 w_NEXPR >> 8, w_NEXPR & 0xFF, 12, 1, 30, 37, 15, 1, 60, 37, 30, 40
    #d8 4, 2, w_ILLQ >> 8, w_ILLQ & 0xFF, w_TEXTSET >> 8, w_TEXTSET & 0xFF, 0
w_TYPE:
    #d8 w_COUNT >> 8, w_COUNT & 0xFF, 12, 4, 10, 15, 25, w_EMIT >> 8, w_EMIT & 0xFF, 34, 14, 33
    #d8 14, 3, 243, w_2DROP >> 8, w_2DROP & 0xFF, 0
w_RAND:
    #d8 1, 0, 2, (rand8) & 0xFF, (rand8) >> 8, 48, 1, 0, 2, (rand8) & 0xFF, (rand8) >> 8, 48
    #d8 2, 0, 1, 42, 27, 0
w_F_ASC:
    #d8 w_SARG >> 8, w_SARG & 0xFF, 12, 25, 4, 4, 33, 25, 3, 3, 13, 1
    #d8 0, 1, 0, 11, 66, 0
w_F_RIGHT:
    #d8 w_STRN >> 8, w_STRN & 0xFF, 1, 41, w_EXPECT >> 8, w_EXPECT & 0xFF, 15, 25, 15, 28, 1, 0
    #d8 w_MAX >> 8, w_MAX & 0xFF, 14, w_SUBSTR >> 8, w_SUBSTR & 0xFF, 0
w_ERRMSG:
    #d8 2, (w_ERRTAB) & 0xFF, (w_ERRTAB) >> 8, 14, 34, 12, 4, 7, 14, w_COUNT >> 8, w_COUNT & 0xFF, 27
    #d8 14, 3, 245, 13, 0
w_F_SGN:
    #d8 w_NARG >> 8, w_NARG & 0xFF, 12, 41, 4, 5, 13, w_TRUE >> 8, w_TRUE & 0xFF, 3, 5, w_0_LT__GT_ >> 8
    #d8 w_0_LT__GT_ & 0xFF, 1, 1, 29, 0
w_DOGOSUB:
    #d8 w_SKIPSTMT >> 8, w_SKIPSTMT & 0xFF, 8, 54, w_CPUSH >> 8, w_CPUSH & 0xFF, 8, 48, w_CPUSH >> 8, w_CPUSH & 0xFF, 1, 1
    #d8 w_CPUSH >> 8, w_CPUSH & 0xFF, w_GOLN >> 8, w_GOLN & 0xFF, 0
w_TABTO:
    #d8 1, 79, w_MIN >> 8, w_MIN & 0xFF, 12, 10, 13, w__GT_ >> 8, w__GT_ & 0xFF, 4, 4, w_SPACE >> 8
    #d8 w_SPACE & 0xFF, 3, 245, 13, 0
w_BEEP_:
    #d8 49, w_ENDS_Q_ >> 8, w_ENDS_Q_ & 0xFF, 4, 4, 1, 69, 3, 2, w_NEXPR >> 8, w_NEXPR & 0xFF, 2
    #d8 (snd_beep) & 0xFF, (snd_beep) >> 8, 48, 13, 0
w_NOTX:
    #d8 49, 1, 175, 37, 4, 7, 51, w_NOTX >> 8, w_NOTX & 0xFF, w_NUMCHK >> 8, w_NUMCHK & 0xFF, 32
    #d8 0, w_CMPX >> 8, w_CMPX & 0xFF, 0
w_F_RND:
    #d8 w_NARG >> 8, w_NARG & 0xFF, 12, 1, 1, 39, 4, 2, w_ILLQ >> 8, w_ILLQ & 0xFF, w_RAND >> 8, w_RAND & 0xFF
    #d8 14, 43, 13, 0
w_U_D_:
    #d8 1, 10, 43, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 2, w_U_D_ >> 8, w_U_D_ & 0xFF, 1, 48, 27
    #d8 w_EMIT >> 8, w_EMIT & 0xFF, 0
w_TEXTBACK:
    #d8 10, 50, 40, 4, 9, w_KEY >> 8, w_KEY & 0xFF, 13, 2, 126, 93, 25
    #d8 w_TEXTSET >> 8, w_TEXTSET & 0xFF, 0
w_F_CHR:
    #d8 w_NARG >> 8, w_NARG & 0xFF, 1, 1, w_TMPALLOC >> 8, w_TMPALLOC & 0xFF, w_TUCK >> 8, w_TUCK & 0xFF, 33, 26, 1, 1
    #d8 11, 66, 0
w_RUNSTART:
    #d8 2, 0, 32, 25, 40, 4, 2, w_WARM >> 8, w_WARM & 0xFF, 2, 0, 32
    #d8 w_GOLINE >> 8, w_GOLINE & 0xFF, 0
w_SGN1:
    #d8 12, 41, 4, 5, 13, w_TRUE >> 8, w_TRUE & 0xFF, 3, 5, w_0_LT__GT_ >> 8, w_0_LT__GT_ & 0xFF, 1
    #d8 1, 29, 0
w_H_D_:
    #d8 1, 16, 43, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 2, w_H_D_ >> 8, w_H_D_ & 0xFF, w_HEXCH >> 8, w_HEXCH & 0xFF, w_EMIT >> 8
    #d8 w_EMIT & 0xFF, 0
w_N_D_:
    #d8 12, 41, 4, 6, 1, 45, w_EMIT >> 8, w_EMIT & 0xFF, w_NEGATE >> 8, w_NEGATE & 0xFF, w_U_D_ >> 8, w_U_D_ & 0xFF
    #d8 0
w_BREAK:
    #d8 8, 54, 9, 72, 8, 48, 9, 74, 1, 14, w_ERROR >> 8, w_ERROR & 0xFF
    #d8 0
w_KWSKIP:
    #d8 12, 25, 1, 128, 29, 40, 4, 3, 33, 3, 245, 33
    #d8 0
w_CPYREST:
    #d8 8, 48, 25, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 5, w_PUTB >> 8, w_PUTB & 0xFF, 51, 3, 244
    #d8 0
w_GOLINE:
    #d8 12, 9, 54, 1, 3, 27, 9, 48, 1, 1, 11, 67
    #d8 0
w_PLOT_:
    #d8 w_NEXPR >> 8, w_NEXPR & 0xFF, w_COMMA >> 8, w_COMMA & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, w_COMMA >> 8, w_COMMA & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, w_PSET >> 8, w_PSET & 0xFF
    #d8 0
w_CARD:
    #d8 1, 0, 2, (mount) & 0xFF, (mount) >> 8, 48, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 2, w_FERR >> 8, w_FERR & 0xFF
    #d8 0
w_FEMIT:
    #d8 12, 1, 10, 37, 4, 4, 1, 13, w_FPUT >> 8, w_FPUT & 0xFF, w_FPUT >> 8, w_FPUT & 0xFF
    #d8 0
w_DOS_:
    #d8 1, 0, 2, (MENU_BLK + MB_PARENT) & 0xFF, (MENU_BLK + MB_PARENT) >> 8, 26, 1, 0, 2, (dos_back) & 0xFF, (dos_back) >> 8, 48
    #d8 0
w_F_STR:
    #d8 w_NARG >> 8, w_NARG & 0xFF, 2, (w_N_D_) & 0xFF, (w_N_D_) >> 8, w_CAPTURE >> 8, w_CAPTURE & 0xFF, 1, 1, 11, 66, 0
w_F_HEX:
    #d8 w_NARG >> 8, w_NARG & 0xFF, 2, (w_H_D_) & 0xFF, (w_H_D_) >> 8, w_CAPTURE >> 8, w_CAPTURE & 0xFF, 1, 1, 11, 66, 0
w_F_LEFT:
    #d8 w_STRN >> 8, w_STRN & 0xFF, 1, 41, w_EXPECT >> 8, w_EXPECT & 0xFF, 1, 0, 14, w_SUBSTR >> 8, w_SUBSTR & 0xFF, 0
w_ZONE:
    #d8 w_SPACE >> 8, w_SPACE & 0xFF, 10, 13, 1, 10, 43, 13, 40, 4, 245, 0
w_BPPM:
    #d8 1, 1, 1, 1, 10, 78, w_LSHIFT >> 8, w_LSHIFT & 0xFF, w_LSHIFT >> 8, w_LSHIFT & 0xFF, 34, 0
w_LSHIFT:
    #d8 12, 4, 6, 14, 35, 14, 34, 3, 247, 13, 0
w_STRLEN:
    #d8 12, 12, 25, 4, 3, 33, 3, 249, 14, 28, 0
w_TMB:
    #d8 10, 51, 4, 4, 1, 4, 3, 2, 1, 0, 0
w_PUTB:
    #d8 2, 114, 93, 23, 26, 2, 114, 93, w_1_P__ST_ >> 8, w_1_P__ST_ & 0xFF, 0
w_CPOP:
    #d8 8, 64, 12, 23, 14, 1, 2, 27, 9, 64, 0
w_TMPEMIT:
    #d8 8, 62, 12, 25, 33, 18, 14, 26, 27, 26, 0
w_NARG:
    #d8 1, 40, w_EXPECT >> 8, w_EXPECT & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, 1, 41, w_EXPECT >> 8, w_EXPECT & 0xFF, 0
w_SARG:
    #d8 1, 40, w_EXPECT >> 8, w_EXPECT & 0xFF, w_SEXPR >> 8, w_SEXPR & 0xFF, 1, 41, w_EXPECT >> 8, w_EXPECT & 0xFF, 0
w_STRN:
    #d8 1, 40, w_EXPECT >> 8, w_EXPECT & 0xFF, w_SEXPR >> 8, w_SEXPR & 0xFF, w_COMMA >> 8, w_COMMA & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, 0
w_GH:
    #d8 2, 224, 1, 8, 76, 28, 10, 79, w_RSHIFT >> 8, w_RSHIFT & 0xFF, 0
w_EXPECT:
    #d8 49, 37, 4, 3, 51, 3, 2, w_SYNERR >> 8, w_SYNERR & 0xFF, 0
w_MKSTR:
    #d8 12, w_TMPALLOC >> 8, w_TMPALLOC & 0xFF, 12, 19, 33, 14, 45, 20, 0
w_SEXPR:
    #d8 w_EXPR >> 8, w_EXPR & 0xFF, 10, 66, 40, 4, 2, w_TMERR >> 8, w_TMERR & 0xFF, 0
w_DEL_:
    #d8 w_FILENAME >> 8, w_FILENAME & 0xFF, 1, 0, 2, (fs_delete) & 0xFF, (fs_delete) >> 8, w_FCALL >> 8, w_FCALL & 0xFF, 0
w_MAX:
    #d8 18, 39, 4, 3, 16, 3, 1, 13, 0
w_PICK:
    #d8 35, 1, 2, 27, 10, (DSP) & 0xFF, 27, 23, 0
w_HOME:
    #d8 1, 0, 11, 13, 1, 0, 11, 14, 0
w_KEY:
    #d8 52, 13, w_KEY_Q_ >> 8, w_KEY_Q_ & 0xFF, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 248, 0
w_FERR:
    #d8 2, 128, 93, 24, 1, 17, w_ERROR >> 8, w_ERROR & 0xFF, 0
w_LINENO:
    #d8 49, 57, 40, 4, 2, w_SYNERR >> 8, w_SYNERR & 0xFF, 50, 0
w_SKIPLINE:
    #d8 8, 48, 25, 4, 3, 51, 3, 248, 0
w_F_VAL:
    #d8 w_SARG >> 8, w_SARG & 0xFF, w_SVAL >> 8, w_SVAL & 0xFF, 1, 0, 11, 66, 0
w_POKE_:
    #d8 w_NEXPR >> 8, w_NEXPR & 0xFF, w_COMMA >> 8, w_COMMA & 0xFF, w_NEXPR >> 8, w_NEXPR & 0xFF, 14, 26, 0
w_GMB:
    #d8 10, 79, 35, 35, 10, 78, 27, 0
w_F_FRE:
    #d8 w_NARG >> 8, w_NARG & 0xFF, 13, w_GC >> 8, w_GC & 0xFF, w_FREE >> 8, w_FREE & 0xFF, 0
w_F_LEN:
    #d8 w_SARG >> 8, w_SARG & 0xFF, 25, 1, 0, 11, 66, 0
w_FORDROP:
    #d8 8, 64, 1, 10, 27, 9, 64, 0
w_GW:
    #d8 2, 128, 2, 10, 78, w_RSHIFT >> 8, w_RSHIFT & 0xFF, 0
w_PPBM:
    #d8 1, 8, 10, 78, w_RSHIFT >> 8, w_RSHIFT & 0xFF, 34, 0
w_FCALL:
    #d8 48, w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 2, w_FERR >> 8, w_FERR & 0xFF, 0
w_WITHIN:
    #d8 15, 28, 19, 28, 20, 38, 0
w_KEY_Q_:
    #d8 1, 0, 2, (kbd_getc) & 0xFF, (kbd_getc) >> 8, 48, 0
w_NUMCHK:
    #d8 10, 66, 4, 2, w_TMERR >> 8, w_TMERR & 0xFF, 0
w_NEW_:
    #d8 w_NEWPROG >> 8, w_NEWPROG & 0xFF, w_CLEARV >> 8, w_CLEARV & 0xFF, w_WARM >> 8, w_WARM & 0xFF, 0
w_1_P__ST_:
    #d8 12, 23, 33, 14, 24, 0
w_1_M__ST_:
    #d8 12, 23, 34, 14, 24, 0
w_ALNUM_Q_:
    #d8 12, 57, 14, 58, 30, 0
w_EMIT:
    #d8 2, 120, 93, 23, 44, 0
w_FREE:
    #d8 8, 60, 8, 58, 28, 0
w__Q_DUP:
    #d8 12, 4, 1, 12, 0
w_COUNT:
    #d8 12, 33, 14, 25, 0
w_CR:
    #d8 1, 10, w_EMIT >> 8, w_EMIT & 0xFF, 0
w_SPACE:
    #d8 1, 32, w_EMIT >> 8, w_EMIT & 0xFF, 0
w_SYNERR:
    #d8 1, 1, w_ERROR >> 8, w_ERROR & 0xFF, 0
w_OOMERR:
    #d8 1, 2, w_ERROR >> 8, w_ERROR & 0xFF, 0
w_ULERR:
    #d8 1, 3, w_ERROR >> 8, w_ERROR & 0xFF, 0
w_TMERR:
    #d8 1, 4, w_ERROR >> 8, w_ERROR & 0xFF, 0
w_D0ERR:
    #d8 1, 5, w_ERROR >> 8, w_ERROR & 0xFF, 0
w_RGERR:
    #d8 1, 6, w_ERROR >> 8, w_ERROR & 0xFF, 0
w_NFERR:
    #d8 1, 7, w_ERROR >> 8, w_ERROR & 0xFF, 0
w_ODERR:
    #d8 1, 8, w_ERROR >> 8, w_ERROR & 0xFF, 0
w_BSERR:
    #d8 1, 9, w_ERROR >> 8, w_ERROR & 0xFF, 0
w_ILLQ:
    #d8 1, 10, w_ERROR >> 8, w_ERROR & 0xFF, 0
w_STLERR:
    #d8 1, 11, w_ERROR >> 8, w_ERROR & 0xFF, 0
w_CCERR:
    #d8 1, 12, w_ERROR >> 8, w_ERROR & 0xFF, 0
w_RDERR:
    #d8 1, 13, w_ERROR >> 8, w_ERROR & 0xFF, 0
w_IDERR:
    #d8 1, 15, w_ERROR >> 8, w_ERROR & 0xFF, 0
w_LAYERR:
    #d8 1, 16, w_ERROR >> 8, w_ERROR & 0xFF, 0
w_COMMA:
    #d8 1, 44, w_EXPECT >> 8, w_EXPECT & 0xFF, 0
w_TMPCOPY:
    #d8 w_COUNT >> 8, w_COUNT & 0xFF, w_MKSTR >> 8, w_MKSTR & 0xFF, 0
w_NEXPR:
    #d8 w_EXPR >> 8, w_EXPR & 0xFF, w_NUMCHK >> 8, w_NUMCHK & 0xFF, 0
w_F_ABS:
    #d8 w_NARG >> 8, w_NARG & 0xFF, w_ABS >> 8, w_ABS & 0xFF, 0
w_GOTO_:
    #d8 w_LINENO >> 8, w_LINENO & 0xFF, w_GOLN >> 8, w_GOLN & 0xFF, 0
w_GOSUB_:
    #d8 w_LINENO >> 8, w_LINENO & 0xFF, w_DOGOSUB >> 8, w_DOGOSUB & 0xFF, 0
w_RESTORE_:
    #d8 1, 0, 9, 70, 0
w_LOAD_:
    #d8 w_LOADFILE >> 8, w_LOADFILE & 0xFF, w_WARM >> 8, w_WARM & 0xFF, 0
w_F_PEEK:
    #d8 w_NARG >> 8, w_NARG & 0xFF, 25, 0
w_2DROP:
    #d8 13, 13, 0
w_TUCK:
    #d8 14, 15, 0
w_NEGATE:
    #d8 32, 33, 0
w__GT_:
    #d8 14, 39, 0
w__LT__GT_:
    #d8 37, 40, 0
w_0_LT__GT_:
    #d8 40, 40, 0
w_LNUM:
    #d8 33, 23, 0
w_F_INKEY:
    #d8 w_KEY_Q_ >> 8, w_KEY_Q_ & 0xFF, 0
w_END_:
    #d8 w_WARM >> 8, w_WARM & 0xFF, 0
w_STOP_:
    #d8 w_BREAK >> 8, w_BREAK & 0xFF, 0
w_REM_:
    #d8 w_SKIPLINE >> 8, w_SKIPLINE & 0xFF, 0
w_DATA_:
    #d8 w_SKIPSTMT >> 8, w_SKIPSTMT & 0xFF, 0
w_CLEAR_:
    #d8 w_CLEARV >> 8, w_CLEARV & 0xFF, 0
w_CLS_:
    #d8 w_SETSCREEN >> 8, w_SETSCREEN & 0xFF, 0

#addr 0xA000
vm_jump:
    ld   p_exit >> 8, y
    jmp  p_exit
    ld   p_lit8 >> 8, y
    jmp  p_lit8
    ld   p_lit16 >> 8, y
    jmp  p_lit16
    ld   p_br >> 8, y
    jmp  p_br
    ld   p_0br >> 8, y
    jmp  p_0br
    ld   p_lbr >> 8, y
    jmp  p_lbr
    ld   p_l0br >> 8, y
    jmp  p_l0br
    ld   p_slit >> 8, y
    jmp  p_slit
    ld   p_zpat >> 8, y
    jmp  p_zpat
    ld   p_zpst >> 8, y
    jmp  p_zpst
    ld   p_zpcat >> 8, y
    jmp  p_zpcat
    ld   p_zpcst >> 8, y
    jmp  p_zpcst
    ld   p_dup >> 8, y
    jmp  p_dup
    ld   p_drop >> 8, y
    jmp  p_drop
    ld   p_swap >> 8, y
    jmp  p_swap
    ld   p_over >> 8, y
    jmp  p_over
    ld   p_nip >> 8, y
    jmp  p_nip
    ld   p_rot >> 8, y
    jmp  p_rot
    ld   p_2dup >> 8, y
    jmp  p_2dup
    ld   p_tor >> 8, y
    jmp  p_tor
    ld   p_rfrom >> 8, y
    jmp  p_rfrom
    ld   p_rat >> 8, y
    jmp  p_rat
    ld   p_rdrop >> 8, y
    jmp  p_rdrop
    ld   p_at >> 8, y
    jmp  p_at
    ld   p_store >> 8, y
    jmp  p_store
    ld   p_cat >> 8, y
    jmp  p_cat
    ld   p_cstore >> 8, y
    jmp  p_cstore
    ld   p_add >> 8, y
    jmp  p_add
    ld   p_sub >> 8, y
    jmp  p_sub
    ld   p_and >> 8, y
    jmp  p_and
    ld   p_or >> 8, y
    jmp  p_or
    ld   p_xor >> 8, y
    jmp  p_xor
    ld   p_invert >> 8, y
    jmp  p_invert
    ld   p_inc >> 8, y
    jmp  p_inc
    ld   p_dec >> 8, y
    jmp  p_dec
    ld   p_2mul >> 8, y
    jmp  p_2mul
    ld   p_2div >> 8, y
    jmp  p_2div
    ld   p_eq >> 8, y
    jmp  p_eq
    ld   p_ult >> 8, y
    jmp  p_ult
    ld   p_lt >> 8, y
    jmp  p_lt
    ld   p_0eq >> 8, y
    jmp  p_0eq
    ld   p_0lt >> 8, y
    jmp  p_0lt
    ld   p_mul >> 8, y
    jmp  p_mul
    ld   p_umod >> 8, y
    jmp  p_umod
    ld   p_execute >> 8, y
    jmp  p_execute
    ld   p_cmove >> 8, y
    jmp  p_cmove
    ld   p_cmoveu >> 8, y
    jmp  p_cmoveu
    ld   p_fill >> 8, y
    jmp  p_fill
    ld   p_sys >> 8, y
    jmp  p_sys
    ld   p_ch >> 8, y
    jmp  p_ch
    ld   p_num >> 8, y
    jmp  p_num
    ld   p_tpinc >> 8, y
    jmp  p_tpinc
    ld   p_poll >> 8, y
    jmp  p_poll
    ld   p_reset >> 8, y
    jmp  p_reset
    ld   p_glyph >> 8, y
    jmp  p_glyph
    ld   p_rowcpy >> 8, y
    jmp  p_rowcpy
    ld   p_vplot >> 8, y
    jmp  p_vplot
    ld   p_digq >> 8, y
    jmp  p_digq
    ld   p_alphq >> 8, y
    jmp  p_alphq
    ld   p_findvar >> 8, y
    jmp  p_findvar
    ld   p_varname >> 8, y
    jmp  p_varname
w_DIMARR:
    #d8 12, 59, 4, 2, w_RDERR >> 8, w_RDERR & 0xFF, 14, 33, 35, w_NEWVAR >> 8, w_NEWVAR & 0xFF, 0
basic:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   MAP_RUN, ac
    ld   ac, [MAP_SHADOW]
    ld   0x50, y
    ld   MAP_RUN, [y,x]
    ld   LINK_LO, x             ; CALL lib_ram_copy
    ld   bas_r32, [x]
    ld   LINK_HI, x
    ld   bas_r32 >> 8, [x]
    ld   lib_ram_copy >> 8, y
    jmp  lib_ram_copy
bas_r32:
    ld   LINK_LO, x             ; CALL port_init
    ld   bas_r33, [x]
    ld   LINK_HI, x
    ld   bas_r33 >> 8, [x]
    ld   port_init >> 8, y
    jmp  port_init
bas_r33:
    ld   LINK_LO, x             ; CALL snd_init
    ld   bas_r34, [x]
    ld   LINK_HI, x
    ld   bas_r34 >> 8, [x]
    ld   snd_init >> 8, y
    jmp  snd_init
bas_r34:
    ld   rc_ram & 0xFF, ac      ; the RAM routines to x5C00 + their offset
    ld   ac, [W0]
bs_cp:
    ld   [W0], x
    ld   rc_ram >> 8, y
    ld   [y,x], ac
    ld   B_RAM, y
    ld   ac, [y,x]
    ld   [W0], ac
    inc
    ld   ac, [W0]
    xor  rc_end & 0xFF, ac
    bne  bs_cp
    ld   DS_EMPTY, ac
    ld   ac, [DSP]
    ld   0xFF, ac
    ld   ac, [RSP]
    ld   w_COLD & 0xFF, ac
    ld   ac, [IPL]
    ld   w_COLD >> 8, ac
    ld   ac, [IPH]
    ld   next >> 8, y
    jmp  next

; ============================================================
; the inner interpreter
; ============================================================
p_exit:
    ld   [RSP], ac
    add  1, x
    ld   RSTK >> 8, y
    ld   [y,x], ac
    ld   ac, [IPL]
    ld   [RSP], ac
    add  2, x
    ld   [y,x], ac
    ld   ac, [IPH]
    ld   [RSP], ac
    add  2, ac
    ld   ac, [RSP]
    ld   next >> 8, y
    jmp  next
p_l0br:                         ; L0BR a: IP = a if TOS = 0, drop it
    ld   [TL], ac
    or   [TH], ac
    ld   ac, [W2]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [W2], ac
    beq  p_lbr
    ld   ip2 >> 8, y
    jmp  ip2
p_lbr:                          ; LBR a: IP = a
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, [W0]
    ld   [IPL], ac
    inc
    ld   ac, x
    bne  lb_1
    ld   [IPH], ac
    inc
    ld   ac, y
lb_1:
    ld   [y,x], ac
    ld   ac, [IPH]
    ld   [W0], ac
    ld   ac, [IPL]
    ld   next >> 8, y
    jmp  next
p_execute:                      ; EXECUTE ( a -- ): call the word at a
    ld   [RSP], x
    ld   RSTK >> 8, y
    ld   [IPH], ac
    ld   ac, [y,x]
    ld   [RSP], ac
    sub  1, x
    ld   [IPL], ac
    ld   ac, [y,x]
    ld   [RSP], ac
    sub  2, ac
    ld   ac, [RSP]
    ld   [TL], ac
    ld   ac, [IPL]
    ld   [TH], ac
    ld   ac, [IPH]
    ld   p_drop >> 8, y
    jmp  p_drop
p_reset:                        ; RESET: empty both stacks (TOS = 0), go on
    ld   DS_EMPTY, ac
    ld   ac, [DSP]
    ld   0xFF, ac
    ld   ac, [RSP]
    clr  ac
    ld   ac, [TL]
    ld   ac, [TH]
    ld   STACK_TOP, ac          ; and the library's stack
    ld   ac, [SP]
    ld   next >> 8, y
    jmp  next

w_CPYSTR:
    #d8 8, 48, 25, w_PUTB >> 8, w_PUTB & 0xFF, 51, 8, 48, 25, 12, 40, 4
    #d8 2, 13, 0, 12, w_PUTB >> 8, w_PUTB & 0xFF, 51, 1, 34, 37, 4, 238
    #d8 0
next:
    ld   [IPH], y               ; Y:X = IP, then IP + 1
    ld   [IPL], x
    ld   [IPL], ac
    inc
    ld   ac, [IPL]
    beq  nx_c
nx_f:
    ld   [y,x], ac
    blt  nx_call
    shl                         ; the primitive: vm_jump + opcode x 4
    shl
    ld   vm_jump >> 8, y
    jmp  ac
nx_c:
    ld   [IPH], ac
    inc
    ld   ac, [IPH]
    bra  nx_f
nx_call:                        ; AC = the word's high byte, IP at its low byte
    ld   ac, [W0]
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, [W1]
    ld   [IPL], ac
    inc
    ld   ac, [IPL]
    bne  nx_2
    ld   [IPH], ac
    inc
    ld   ac, [IPH]
nx_2:
    ld   [RSP], x               ; push IP on the return stack
    ld   RSTK >> 8, y
    ld   [IPH], ac
    ld   ac, [y,x]
    ld   [RSP], ac
    sub  1, x
    ld   [IPL], ac
    ld   ac, [y,x]
    ld   [RSP], ac
    sub  2, ac
    ld   ac, [RSP]
    ld   [W1], ac
    ld   ac, [IPL]
    ld   [W0], ac
    ld   ac, [IPH]
    bra  next
ip2:
    ld   [IPL], ac
    add  2, ac
    ld   ac, [IPL]
    bcc  next
    ld   [IPH], ac
    inc
    ld   ac, [IPH]
    bra  next
ip1:
    ld   [IPL], ac
    inc
    ld   ac, [IPL]
    bne  next
    ld   [IPH], ac
    inc
    ld   ac, [IPH]
    bra  next
p_br:                           ; BR n: IP = IP + 1 + n (n signed)
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, [W0]
    add  [IPL], ac
    ld   ac, [IPL]
    bcc  br_nc
    ld   [W0], ac
    blt  ip1                    ; back, with a carry: the same page
    ld   [IPH], ac
    inc
    ld   ac, [IPH]
    bra  ip1
br_nc:
    ld   [W0], ac
    blt  br_dec
    bra  ip1
br_dec:
    ld   [IPH], ac
    dec
    ld   ac, [IPH]
    bra  ip1
p_0br:                          ; 0BR n: branch if TOS = 0, drop it
    ld   [TL], ac
    or   [TH], ac
    ld   ac, [W2]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [W2], ac
    beq  p_br
    bra  ip1

; R0-R7 as set
p_sys:
    ld   [TL], ac
    ld   ac, [W0]
    ld   [TH], ac
    ld   ac, [W1]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   LINK_LO, x
    ld   sy_back, [x]
    ld   LINK_HI, x
    ld   sy_back >> 8, [x]
    ld   [TL], ac
    ld   [W1], y
    jmp  [W0]
sy_back:
    ld   ac, [TL]
    clr  ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next

w_HEXDIG:
    #d8 12, 57, 4, 4, 1, 48, 28, 0, 12, 1, 65, 1
    #d8 71, w_WITHIN >> 8, w_WITHIN & 0xFF, 4, 4, 1, 55, 28, 0, 13, w_TRUE >> 8, w_TRUE & 0xFF
    #d8 0
p_lit8:                         ; LIT8 n ( -- n )
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, [TL]
    clr  ac
    ld   ac, [TH]
    ld   ip1 >> 8, y
    jmp  ip1
p_lit16:                        ; LIT16 n ( -- n )
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, [TL]
    ld   [IPL], ac
    inc
    ld   ac, [IPL]
    bne  ii14
    ld   [IPH], ac
    inc
    ld   ac, [IPH]
ii14:
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, [TH]
    ld   ip1 >> 8, y
    jmp  ip1
p_slit:                         ; SLIT n "..." ( -- a ): a = the length byte's address
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [IPL], ac
    ld   ac, [TL]
    ld   [IPH], ac
    ld   ac, [TH]
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    inc
    add  [IPL], ac
    ld   ac, [IPL]
    bcc  sl_nc
    ld   [IPH], ac
    inc
    ld   ac, [IPH]
sl_nc:
    ld   next >> 8, y
    jmp  next

p_at:                           ; @ ( a -- [a] )
    ld   [TH], y
    ld   [TL], x
    ld   [y,x], ac
    ld   ac, [W0]
    ld   [TL], ac
    inc
    ld   ac, x
    bne  at_1
    ld   [TH], ac
    inc
    ld   ac, y
at_1:
    ld   [y,x], ac
    ld   ac, [TH]
    ld   [W0], ac
    ld   ac, [TL]
    ld   next >> 8, y
    jmp  next
p_cat:                          ; C@ ( a -- [a] ), one byte
    ld   [TH], y
    ld   [TL], x
    ld   [y,x], ac
    ld   ac, [TL]
    clr  ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_store:                        ; ! ( v a -- )
    ld   [DSP], ac              ; W0 = v high
    add  1, x
    ld   [x], ac
    ld   ac, [W0]
    ld   [DSP], x               ; v low
    ld   [x], ac
    ld   [TH], y
    ld   [TL], x
    ld   ac, [y,x]
    ld   [TL], ac
    inc
    ld   ac, x
    bne  st_1
    ld   [TH], ac
    inc
    ld   ac, y
st_1:
    ld   [W0], ac
    ld   ac, [y,x]
st_pop2:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   next >> 8, y
    jmp  next
p_cstore:                       ; C! ( v a -- )
    ld   [DSP], x
    ld   [x], ac
    ld   [TH], y
    ld   [TL], x
    ld   ac, [y,x]
    bra  st_pop2

w_NEWPROG:
    #d8 2, 0, 32, 9, 56, 1, 0, 2, 0, 32, 26, 1
    #d8 0, 9, 72, 0
p_zpat:                         ; ZP@ n ( -- [n] )
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, [W0]
    ld   ac, x
    ld   [x], ac
    ld   ac, [TL]
    ld   [W0], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   ip1 >> 8, y
    jmp  ip1
p_zpcat:                        ; ZPC@ n ( -- [n] ), one byte
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, x
    ld   [x], ac
    ld   ac, [TL]
    clr  ac
    ld   ac, [TH]
    ld   ip1 >> 8, y
    jmp  ip1
p_zpst:                         ; ZP! n ( v -- )
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, [W0]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [W0], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   ip1 >> 8, y
    jmp  ip1
p_zpcst:                        ; ZPC! n ( v -- ), one byte
    ld   [IPH], y
    ld   [IPL], x
    ld   [y,x], ac
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   ip1 >> 8, y
    jmp  ip1

p_mul:
    ld   [DSP], x               ; W1:W0 = a, W3:W2 = 0
    ld   [x], ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [W1]
    clr  ac
    ld   ac, [W2]
    ld   ac, [W3]
mu_lp:
    ld   [TL], ac
    and  1, ac
    beq  mu_sh
    ld   [W2], ac
    add  [W0], ac
    ld   ac, [W2]
    bcc  mu_hi
    ld   [W3], ac
    inc
    ld   ac, [W3]
mu_hi:
    ld   [W3], ac
    add  [W1], ac
    ld   ac, [W3]
mu_sh:
    ld   [W0], ac               ; a << 1
    shl
    ld   ac, [W0]
    ld   [W1], ac
    bcc  mu_a0
    shl
    or   1, ac
    bra  mu_a1
mu_a0:
    shl
mu_a1:
    ld   ac, [W1]
    ld   [TL], ac               ; b >> 1
    shr  ac
    ld   ac, [TL]
    ld   [TH], ac
    and  1, ac
    beq  mu_b0
    ld   [TL], ac
    or   0x80, ac
    ld   ac, [TL]
mu_b0:
    ld   [TH], ac
    shr  ac
    ld   ac, [TH]
    or   [TL], ac
    bne  mu_lp
    ld   [W2], ac
    ld   ac, [TL]
    ld   [W3], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   next >> 8, y
    jmp  next

w_MIN:
    #d8 18, 39, 4, 3, 13, 3, 1, 16, 0
p_dup:
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   next >> 8, y
    jmp  next
p_drop:
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   next >> 8, y
    jmp  next
p_nip:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   next >> 8, y
    jmp  next
p_swap:
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [W0]
    ld   [TL], ac
    ld   ac, [x]
    ld   [W0], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [W0]
    ld   [TH], ac
    ld   ac, [x]
    ld   [W0], ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_over:                         ; ( a b -- a b a )
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  2, x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  3, x
    ld   [x], ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_2dup:                         ; ( a b -- a b a b )
    ld   [DSP], ac              ; W1:W0 = a
    ld   ac, x
    ld   [x], ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [W1]
    ld   [DSP], ac              ; two cells more: b, then a below TOS
    sub  4, ac
    ld   ac, [DSP]
    add  2, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  3, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [DSP], x
    ld   [W0], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [W1], ac
    ld   ac, [x]
    ld   next >> 8, y
    jmp  next

p_fill:
    ld   [TL], ac               ; W4 = c, TOS = n, W1:W0 = a
    ld   ac, [W4]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [W1]
fi_lp:
    ld   [TL], ac
    or   [TH], ac
    beq  fi_done
    ld   [W1], y
    ld   [W0], x
    ld   [W4], ac
    ld   ac, [y,x]
    ld   [W0], ac
    inc
    ld   ac, [W0]
    bne  fi_1
    ld   [W1], ac
    inc
    ld   ac, [W1]
fi_1:
    ld   [TL], ac
    sub  1, ac
    ld   ac, [TL]
    bcc  fi_lp
    ld   [TH], ac
    dec
    ld   ac, [TH]
    bra  fi_lp
fi_done:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   p_drop >> 8, y
    jmp  p_drop

w_TRUE:
    #d8 2, 255, 255, 0
p_rot:                          ; ( a b c -- b c a )
    ld   [DSP], ac              ; W1:W0 = a (at DSP + 2)
    add  2, x
    ld   [x], ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  3, x
    ld   [x], ac
    ld   ac, [W1]
    ld   [DSP], x               ; DSP + 2 = b
    ld   [x], ac
    ld   ac, [W2]
    ld   [DSP], ac
    add  2, x
    ld   [W2], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [W2]
    ld   [DSP], ac
    add  3, x
    ld   [W2], ac
    ld   ac, [x]
    ld   [DSP], x               ; DSP = c
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [W0], ac               ; TOS = a
    ld   ac, [TL]
    ld   [W1], ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_tor:                          ; >R ( a -- )
    ld   [RSP], x
    ld   RSTK >> 8, y
    ld   [TH], ac
    ld   ac, [y,x]
    ld   [RSP], ac
    sub  1, x
    ld   [TL], ac
    ld   ac, [y,x]
    ld   [RSP], ac
    sub  2, ac
    ld   ac, [RSP]
    ld   p_drop >> 8, y
    jmp  p_drop
p_rfrom:                        ; R> ( -- a )
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [RSP], ac
    add  2, ac
    ld   ac, [RSP]
    bra  rf_get
p_rat:                          ; R@ ( -- a )
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   [RSP], ac
    add  2, ac
rf_get:                         ; TOS = the return stack entry at AC - 1 (low), AC (high)
    ld   ac, [W0]
    ld   ac, x
    ld   RSTK >> 8, y
    ld   [y,x], ac
    ld   ac, [TH]
    ld   [W0], ac
    sub  1, x
    ld   [y,x], ac
    ld   ac, [TL]
    ld   next >> 8, y
    jmp  next
p_rdrop:
    ld   [RSP], ac
    add  2, ac
    ld   ac, [RSP]
    ld   next >> 8, y
    jmp  next

; f = Esc is down
p_poll:
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    ld   LINK_LO, x             ; CALL frame_poll
    ld   bas_r35, [x]
    ld   LINK_HI, x
    ld   bas_r35 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
bas_r35:
    ld   [FRAME_LO], ac
    xor  [LASTFR], ac
    beq  po_esc
    ld   [FRAME_LO], ac
    ld   ac, [LASTFR]
    ld   LINK_LO, x             ; CALL snd_update
    ld   bas_r36, [x]
    ld   LINK_HI, x
    ld   bas_r36 >> 8, [x]
    ld   snd_update >> 8, y
    jmp  snd_update
bas_r36:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   bas_r37, [x]
    ld   LINK_HI, x
    ld   bas_r37 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
bas_r37:
po_esc:
    clr  ac
    ld   ac, [TH]
    ld   [KBD_NOW], ac          ; Esc is key 0: bit 0 = 0 while down
    and  1, ac
    xor  1, ac
    ld   ac, [TL]
    ld   next >> 8, y
    jmp  next

; ============================================================
; the screen
; ============================================================
; Text row R's glyph row k is at x6000 + column * 512 + offset + k * step:
;   80 x 60 (1x rows):  offset 32 + 8R, step 1
;   80 x 30 (2x rows):  offset x120 + 16R (R < 14), x101 + 16(R - 14), step 2
; (screen line y's byte, v = y + 32: 1x at v, 2x at x100 | v7:v1 | v8)
w_RSHIFT:
    #d8 12, 4, 10, 14, 36, 2, 255, 127, 29, 14, 34, 3
    #d8 243, 13, 0
p_add:
    ld   [DSP], x
    ld   [x], ac
    add  [TL], ac
    ld   ac, [TL]
    bcc  vad_1
    ld   [TH], ac
    inc
    ld   ac, [TH]
vad_1:
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    add  [TH], ac
    ld   ac, [TH]
ad_nip:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   next >> 8, y
    jmp  next
p_sub:                          ; - ( a b -- a-b )
    ld   [DSP], x
    ld   [x], ac
    sub  [TL], ac
    ld   ac, [TL]
    bcc  sb_1
    ld   [TH], ac               ; a borrow: take one more from the high byte
    inc
    ld   ac, [TH]
sb_1:
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    sub  [TH], ac
    ld   ac, [TH]
    bra  ad_nip
p_and:
    ld   [DSP], x
    ld   [x], ac
    and  [TL], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    and  [TH], ac
    ld   ac, [TH]
    bra  ad_nip
p_or:
    ld   [DSP], x
    ld   [x], ac
    or   [TL], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    or   [TH], ac
    ld   ac, [TH]
    bra  ad_nip
p_xor:
    ld   [DSP], x
    ld   [x], ac
    xor  [TL], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    xor  [TH], ac
    ld   ac, [TH]
    bra  ad_nip

p_invert:
    ld   [TL], ac
    not
    ld   ac, [TL]
    ld   [TH], ac
    not
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_inc:
    ld   [TL], ac
    inc
    ld   ac, [TL]
    bne  in_1
    ld   [TH], ac
    inc
    ld   ac, [TH]
in_1:
    ld   next >> 8, y
    jmp  next
p_dec:
    ld   [TL], ac
    sub  1, ac
    ld   ac, [TL]
    bcc  in_1
    ld   [TH], ac
    dec
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_2mul:
    ld   [TL], ac
    shl
    ld   ac, [TL]
    ld   [TH], ac
    bcc  m2_1
    shl
    or   1, ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
m2_1:
    shl
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_2div:                         ; arithmetic: the sign stays
    ld   [TL], ac
    shr  ac
    ld   ac, [TL]
    ld   [TH], ac
    and  1, ac
    beq  d2_1
    ld   [TL], ac
    or   0x80, ac
    ld   ac, [TL]
d2_1:
    ld   [TH], ac
    and  0x80, ac
    ld   ac, [W0]
    ld   [TH], ac
    shr  ac
    or   [W0], ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_tpinc:                        ; TP+: TP + 1
    ld   [TP], ac
    inc
    ld   ac, [TP]
    bne  in_1
    ld   [TP + 1], ac
    inc
    ld   ac, [TP + 1]
    ld   next >> 8, y
    jmp  next

w_UPC:
    #d8 12, 1, 97, 1, 123, w_WITHIN >> 8, w_WITHIN & 0xFF, 4, 3, 1, 32, 28
    #d8 0
; name = the first letter (+ x80 for $), high byte the second letter or
; digit or 0 (+ x80 for an array: the ( is left at TP); further letters
; and digits are skipped.  W2 = the state: 0 first letter, 1 second,
; 2 the rest, 3 after the $; W3 = the character.
p_varname:
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    clr  ac
    ld   ac, [W2]
vn_lp:
    ld   [TP + 1], y
    ld   [TP], x
    ld   [y,x], ac
    ld   ac, [W3]
    xor  0x20, ac
    beq  vn_inc                 ; a space
    ld   [W2], ac
    bne  vn_1
    ld   [W3], ac               ; the first letter
    ld   ac, [TL]
    clr  ac
    ld   ac, [TH]
    ld   1, ac
    ld   ac, [W2]
    bra  vn_inc
vn_1:
    sub  3, ac
    beq  vn_paren
    ld   [W3], ac
    sub  0x30, ac
    sub  10, ac
    bcs  vn_an
    ld   [W3], ac
    sub  0x41, ac
    sub  26, ac
    bcc  vn_suf
vn_an:                          ; a letter or digit
    ld   [W2], ac
    sub  1, ac
    bne  vn_inc
    ld   [W3], ac               ; the second
    ld   ac, [TH]
    ld   2, ac
    ld   ac, [W2]
vn_inc:
    ld   [TP], ac
    inc
    ld   ac, [TP]
    bne  vn_lp
    ld   [TP + 1], ac
    inc
    ld   ac, [TP + 1]
    bra  vn_lp
vn_suf:
    ld   [W3], ac
    xor  0x24, ac               ; $
    bne  vn_paren
    ld   [TL], ac
    or   0x80, ac
    ld   ac, [TL]
    ld   3, ac
    ld   ac, [W2]
    bra  vn_inc
vn_paren:
    ld   [W3], ac
    xor  0x28, ac               ; (
    bne  vn_x
    ld   [TH], ac
    or   0x80, ac
    ld   ac, [TH]
vn_x:
    ld   next >> 8, y
    jmp  next

; The records from VBASE (x0100) to [VTOP]: [name][size][data], each an
; even number of bytes, so a record's name, and its size, never cross a page.
VTOP    = 0x3A
p_findvar:
    ld   0x01, ac               ; W1:W0 = VBASE
    ld   ac, [W1]
    clr  ac
    ld   ac, [W0]
fv_lp:
    ld   [W1], ac               ; W1:W0 below VTOP?
    sub  [VTOP + 1], ac
    bcs  fv_in
    bne  fv_none
    ld   [W0], ac
    sub  [VTOP], ac
    bcc  fv_none
fv_in:
    ld   [W1], y
    ld   [W0], x
    ld   [y,x], ac
    xor  [TL], ac
    ld   ac, [W2]
    ld   [W0], ac
    add  1, x
    ld   [y,x], ac
    xor  [TH], ac
    or   [W2], ac
    beq  fv_found
    ld   [W0], ac               ; W5:W4 = the size
    add  2, ac
    ld   ac, x
    ld   [W1], ac
    bcc  fv_s
    inc
fv_s:
    ld   ac, y
    ld   [y,x], ac
    ld   ac, [W4]
    ld   [W0], ac
    add  3, x
    ld   [y,x], ac
    ld   ac, [W5]
    ld   [W0], ac               ; W1:W0 += size + 4
    add  [W4], ac
    ld   ac, [W0]
    ld   [W1], ac
    bcc  fv_n1
    inc
fv_n1:
    add  [W5], ac
    ld   ac, [W1]
    ld   [W0], ac
    add  4, ac
    ld   ac, [W0]
    bcc  fv_lp
    ld   [W1], ac
    inc
    ld   ac, [W1]
    bra  fv_lp
fv_found:
    ld   [W0], ac
    add  4, ac
    ld   ac, [TL]
    ld   [W1], ac
    bcc  fv_f1
    inc
fv_f1:
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
fv_none:
    clr  ac
    ld   ac, [TL]
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next


#addr 0xA900
p_eq:
    ld   [DSP], x
    ld   [x], ac
    xor  [TL], ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    xor  [TH], ac
    or   [W0], ac
    beq  t_true
    bra  t_false
p_ult:
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    sub  [TH], ac
    bcs  t_true
    bne  t_false
ult_lo:
    ld   [DSP], x
    ld   [x], ac
    sub  [TL], ac
    bcs  t_true
t_false:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
u_false:
    clr  ac
    ld   ac, [TL]
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_lt:                           ; signed: compare with the sign bits flipped
    ld   [TH], ac
    xor  0x80, ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    xor  0x80, ac
    sub  [W0], ac
    bcs  t_true
    bne  t_false
    bra  ult_lo
t_true:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
u_true:
    ld   0xFF, ac
    ld   ac, [TL]
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next
p_0eq:
    ld   [TL], ac
    or   [TH], ac
    beq  u_true
    bra  u_false
p_0lt:
    ld   [TH], ac
    blt  u_true
    bra  u_false
p_digq:                         ; DIGIT? ( c -- f ): c is 0-9
    ld   [TH], ac
    bne  u_false
    ld   [TL], ac
    sub  0x30, ac
    sub  10, ac
    bcs  u_true
    bra  u_false
p_alphq:                        ; ALPHA? ( c -- f ): c is A-Z
    ld   [TH], ac
    bne  u_false
    ld   [TL], ac
    sub  0x41, ac
    sub  26, ac
    bcs  u_true
    bra  u_false

p_cmove:
    ld   [DSP], x               ; W1:W0 = to, W3:W2 = from, TOS = n
    ld   [x], ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [W1]
    ld   [DSP], ac
    add  2, x
    ld   [x], ac
    ld   ac, [W2]
    ld   [DSP], ac
    add  3, x
    ld   [x], ac
    ld   ac, [W3]
cm_lp:
    ld   [TL], ac
    or   [TH], ac
    beq  cm_done
    ld   [W3], y
    ld   [W2], x
    ld   [y,x], ac
    ld   [W1], y
    ld   [W0], x
    ld   ac, [y,x]
    ld   [W2], ac
    inc
    ld   ac, [W2]
    bne  cm_1
    ld   [W3], ac
    inc
    ld   ac, [W3]
cm_1:
    ld   [W0], ac
    inc
    ld   ac, [W0]
    bne  cm_2
    ld   [W1], ac
    inc
    ld   ac, [W1]
cm_2:
    ld   [TL], ac
    sub  1, ac
    ld   ac, [TL]
    bcc  cm_lp
    ld   [TH], ac
    dec
    ld   ac, [TH]
    bra  cm_lp
cm_done:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   p_drop >> 8, y
    jmp  p_drop

w_DELLN:
    #d8 12, 25, 19, 12, 21, 27, 14, 8, 56, 33, 15, 28
    #d8 21, 28, 45, 8, 56, 20, 28, 9, 56, 0
p_umod:
    ld   [DSP], x               ; W1:W0 = a (becomes the quotient)
    ld   [x], ac
    ld   ac, [W0]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [W1]
    clr  ac                     ; W3:W2 = the remainder
    ld   ac, [W2]
    ld   ac, [W3]
    ld   16, ac
    ld   ac, [W4]
um_lp:
    ld   [W0], ac               ; W3:W2:W1:W0 << 1
    shl
    ld   ac, [W0]
    ld   [W1], ac
    bcc  um_1
    shl
    or   1, ac
    bra  um_2
um_1:
    shl
um_2:
    ld   ac, [W1]
    ld   [W2], ac
    bcc  um_3
    shl
    or   1, ac
    bra  um_4
um_3:
    shl
um_4:
    ld   ac, [W2]
    ld   [W3], ac
    bcc  um_5
    shl
    or   1, ac
    ld   ac, [W3]
    bra  um_sub                 ; bit 16 set: the remainder is more than b
um_5:
    shl
    ld   ac, [W3]
    sub  [TH], ac               ; remainder >= b?
    bcs  um_next
    bne  um_sub
    ld   [W2], ac
    sub  [TL], ac
    bcs  um_next
um_sub:
    ld   [W2], ac               ; remainder - b, quotient bit 1
    sub  [TL], ac
    ld   ac, [W2]
    ld   [W3], ac
    bcc  um_6
    dec
um_6:
    sub  [TH], ac
    ld   ac, [W3]
    ld   [W0], ac
    or   1, ac
    ld   ac, [W0]
um_next:
    ld   [W4], ac
    dec
    ld   ac, [W4]
    bne  um_lp
    ld   [DSP], x               ; below: the remainder, TOS: the quotient
    ld   [W2], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [W3], ac
    ld   ac, [x]
    ld   [W0], ac
    ld   ac, [TL]
    ld   [W1], ac
    ld   ac, [TH]
    ld   next >> 8, y
    jmp  next

p_cmoveu:
    ld   [DSP], x               ; W1:W0 = to + n, W3:W2 = from + n
    ld   [x], ac
    add  [TL], ac
    ld   ac, [W0]
    ld   [TH], ac
    bcc  cu_1
    inc
cu_1:
    ld   ac, [W1]
    ld   [DSP], ac
    add  1, x
    ld   [W1], ac
    add  [x], ac
    ld   ac, [W1]
    ld   [DSP], ac
    add  2, x
    ld   [x], ac
    add  [TL], ac
    ld   ac, [W2]
    ld   [TH], ac
    bcc  cu_2
    inc
cu_2:
    ld   ac, [W3]
    ld   [DSP], ac
    add  3, x
    ld   [W3], ac
    add  [x], ac
    ld   ac, [W3]
cu_lp:
    ld   [TL], ac
    or   [TH], ac
    beq  cu_done
    ld   [W2], ac               ; from - 1
    sub  1, ac
    ld   ac, [W2]
    bcc  cu_3
    ld   [W3], ac
    dec
    ld   ac, [W3]
cu_3:
    ld   [W0], ac               ; to - 1
    sub  1, ac
    ld   ac, [W0]
    bcc  cu_4
    ld   [W1], ac
    dec
    ld   ac, [W1]
cu_4:
    ld   [W3], y
    ld   [W2], x
    ld   [y,x], ac
    ld   [W1], y
    ld   [W0], x
    ld   ac, [y,x]
    ld   [TL], ac
    sub  1, ac
    ld   ac, [TL]
    bcc  cu_lp
    ld   [TH], ac
    dec
    ld   ac, [TH]
    bra  cu_lp
cu_done:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   p_drop >> 8, y
    jmp  p_drop

; NUM ( -- n ): digits at TP
p_ch:
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    clr  ac
    ld   ac, [TH]
ch_lp:
    ld   [TP + 1], y
    ld   [TP], x
    ld   [y,x], ac
    ld   ac, [TL]
    xor  0x20, ac
    bne  ch_done
    ld   [TP], ac
    inc
    ld   ac, [TP]
    bne  ch_lp
    ld   [TP + 1], ac
    inc
    ld   ac, [TP + 1]
    bra  ch_lp
ch_done:
    ld   next >> 8, y
    jmp  next
p_num:
    ld   [DSP], ac
    sub  2, ac
    ld   ac, [DSP]
    ld   ac, x
    ld   [TL], ac
    ld   ac, [x]
    ld   [DSP], ac
    add  1, x
    ld   [TH], ac
    ld   ac, [x]
    clr  ac
    ld   ac, [TL]
    ld   ac, [TH]
nm_lp:
    ld   [TP + 1], y
    ld   [TP], x
    ld   [y,x], ac
    sub  0x30, ac
    ld   ac, [W0]
    sub  10, ac
    bcc  ch_done                ; not a digit
    ld   [TL], ac               ; W2:W1 = n * 2
    shl
    ld   ac, [W1]
    ld   [TH], ac
    bcc  nm_1
    shl
    or   1, ac
    bra  nm_2
nm_1:
    shl
nm_2:
    ld   ac, [W2]
    ld   [W1], ac               ; n * 8
    shl
    ld   ac, [TL]
    ld   [W2], ac
    bcc  nm_3
    shl
    or   1, ac
    bra  nm_4
nm_3:
    shl
nm_4:
    ld   ac, [TH]
    ld   [TL], ac
    shl
    ld   ac, [TL]
    ld   [TH], ac
    bcc  nm_5
    shl
    or   1, ac
    bra  nm_6
nm_5:
    shl
nm_6:
    ld   ac, [TH]
    ld   [TL], ac               ; n * 8 + n * 2
    add  [W1], ac
    ld   ac, [TL]
    bcc  nm_7
    ld   [TH], ac
    inc
    ld   ac, [TH]
nm_7:
    ld   [TH], ac
    add  [W2], ac
    ld   ac, [TH]
    ld   [TL], ac               ; + the digit
    add  [W0], ac
    ld   ac, [TL]
    bcc  nm_8
    ld   [TH], ac
    inc
    ld   ac, [TH]
nm_8:
    ld   [TP], ac
    inc
    ld   ac, [TP]
    bne  nm_lp
    ld   [TP + 1], ac
    inc
    ld   ac, [TP + 1]
    bra  nm_lp

w_INSLN:
    #d8 8, 48, w_STRLEN >> 8, w_STRLEN & 0xFF, 1, 4, 27, 12, 1, 255, w__GT_ >> 8, w__GT_ & 0xFF
    #d8 4, 2, w_STLERR >> 8, w_STLERR & 0xFF, 12, 8, 56, 27, 2, 0, 77, 38
    #d8 40, 4, 2, w_OOMERR >> 8, w_OOMERR & 0xFF, 19, 12, 12, 21, 27, 8, 56
    #d8 33, 1, 3, w_PICK >> 8, w_PICK & 0xFF, 28, 46, 21, 15, 26, w_TUCK >> 8, w_TUCK & 0xFF
    #d8 33, 24, 8, 48, 14, 1, 3, 27, 21, 1, 3, 28
    #d8 45, 8, 56, 20, 27, 9, 56, 0
w_EMPTYS:
    #d8 0
; ROWCPY ( from to -- ): copy a text row
p_glyph:
    clr  ac
    ld   ac, [W7]               ; rowbase returns to gl_row
    ld   [CUR_ROW], ac
    bra  rowbase
gl_row:
    ld   [CUR_COL], ac          ; W1 = x60 + 2 * column + the offset's bit 8
    shl
    add  [W1], ac
    ld   ac, [W1]
    ld   LIB_FONT >> 8, ac
    ld   ac, [W3]
gl_lp:
    ld   [TL], x
    ld   [W3], y
    ld   [y,x], ac
    ld   [W1], y
    ld   [W0], x
    ld   ac, [y,x]
    ld   [W0], ac
    add  [W2], ac
    ld   ac, [W0]
    ld   [W3], ac
    inc
    ld   ac, [W3]
    xor  (LIB_FONT >> 8) + 8, ac
    bne  gl_lp
    ld   p_drop >> 8, y
    jmp  p_drop
rowbase:                        ; AC = row: W0 = offset low, W1 = x60 + bit 8, W2 = step
    ld   ac, [W5]
    ld   [TXT2X], ac
    bne  rb_2x
    ld   1, ac
    ld   ac, [W2]
    ld   0x60, ac
    ld   ac, [W1]
    ld   [W5], ac
    sub  28, ac                 ; rows 28-59: the column's second page, 8 * (R - 28)
    blt  rb_1lo
    shl
    shl
    shl
    ld   ac, [W0]
    ld   0x61, ac
    ld   ac, [W1]
    bra  rb_done
rb_1lo:
    add  28 + 4, ac             ; rows 0-27: 8 * R + 32
    shl
    shl
    shl
    ld   ac, [W0]
    bra  rb_done
rb_2x:
    ld   2, ac
    ld   ac, [W2]
    ld   0x61, ac
    ld   ac, [W1]
    ld   [W5], ac
    sub  14, ac
    blt  rb_top
    shl
    shl
    shl
    shl
    or   1, ac
    ld   ac, [W0]
    bra  rb_done
rb_top:
    ld   [W5], ac
    shl
    shl
    shl
    shl
    add  0x20, ac
    ld   ac, [W0]
rb_done:
    ld   [W7], ac
    beq  gl_row
    sub  1, ac
    beq  rc_from
    bra  rc_to
p_rowcpy:
    ld   1, ac
    ld   ac, [W7]
    ld   [DSP], x               ; the source row
    ld   [x], ac
    bra  rowbase
rc_from:                        ; T0-T7 = the source offsets, SPG
    ld   [W1], ac
    ld   ac, [SPG]
    ld   T0, ac
    ld   ac, [W6]
rc_f1:
    ld   [W6], x
    ld   [W0], ac
    ld   ac, [x]
    add  [W2], ac
    ld   ac, [W0]
    ld   [W6], ac
    inc
    ld   ac, [W6]
    xor  T0 + 8, ac
    bne  rc_f1
    ld   2, ac
    ld   ac, [W7]
    ld   [TL], ac               ; the destination row
    bra  rowbase
rc_to:                          ; R0-R7 = the destination offsets, DPG
    ld   [W1], ac
    ld   ac, [DPG]
    ld   R0, ac
    ld   ac, [W6]
vrc_t1:
    ld   [W6], x
    ld   [W0], ac
    ld   ac, [x]
    add  [W2], ac
    ld   ac, [W0]
    ld   [W6], ac
    inc
    ld   ac, [W6]
    xor  R0 + 8, ac
    bne  vrc_t1
    ld   80, ac
    ld   ac, [W4]
    ld   B_RAM, y
    jmp  rc_ram & 0xFF
rc_back:
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   p_drop >> 8, y
    jmp  p_drop

w_KWMATCH:
    #d8 2, (w_KWTAB) & 0xFF, (w_KWTAB) >> 8, 1, 128, 15, 25, 4, 21, 15, w_KWCMP >> 8, w_KWCMP & 0xFF
    #d8 w__Q_DUP >> 8, w__Q_DUP & 0xFF, 4, 7, 8, 48, 27, 9, 48, 16, 0, 14
    #d8 w_KWSKIP >> 8, w_KWSKIP & 0xFF, 14, 33, 3, 231, w_2DROP >> 8, w_2DROP & 0xFF, 1, 0, 0
p_vplot:
    ld   [TL], ac               ; W3 = bits
    ld   ac, [W3]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [TL], ac               ; W4 = ~mask
    not
    ld   ac, [W4]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [TL], ac               ; R3:R2 = line
    ld   ac, [R2]
    ld   [TH], ac
    ld   ac, [R3]
    ld   [DSP], x
    ld   [x], ac
    ld   ac, [TL]
    ld   [DSP], ac
    add  1, x
    ld   [x], ac
    ld   ac, [TH]
    ld   [DSP], ac
    add  2, ac
    ld   ac, [DSP]
    ld   [TL], ac               ; AC = column
    ld   LINK_LO, x             ; AC = the byte's page, X = its low byte (kept to the end)
    ld   bas_r38, [x]
    ld   LINK_HI, x
    ld   bas_r38 >> 8, [x]
    ld   vid_addr >> 8, y
    jmp  vid_addr
bas_r38:
    ld   ac, [W6]
    ld   B_RAM, y
    jmp  vr_ram & 0xFF
vr_back:                        ; AC = the byte
    and  [W4], ac
    or   [W3], ac
    ld   [W6], y
    ld   ac, [y,x]
    ld   p_drop >> 8, y
    jmp  p_drop

; ------------------------------------------------------------
; the RAM routines: copied to x5C00 + their offset (basic:), they map
; the video RAM in to read it.  Only branches inside the page, and jumps
; to fixed addresses.
; ------------------------------------------------------------
; vr_ram: read a video byte
rc_ram:
    ld   0x50, y
    ld   0xFF, [y,x]            ; map FF: every section RAM
rcr_col:
    ld   [SPG], y
    ld   [T0], x
    ld   [y,x], ac
    ld   [DPG], y
    ld   [R0], x
    ld   ac, [y,x]
    ld   [SPG], y
    ld   [T1], x
    ld   [y,x], ac
    ld   [DPG], y
    ld   [R1], x
    ld   ac, [y,x]
    ld   [SPG], y
    ld   [T2], x
    ld   [y,x], ac
    ld   [DPG], y
    ld   [R2], x
    ld   ac, [y,x]
    ld   [SPG], y
    ld   [T3], x
    ld   [y,x], ac
    ld   [DPG], y
    ld   [R3], x
    ld   ac, [y,x]
    ld   [SPG], y
    ld   [T4], x
    ld   [y,x], ac
    ld   [DPG], y
    ld   [R4], x
    ld   ac, [y,x]
    ld   [SPG], y
    ld   [T5], x
    ld   [y,x], ac
    ld   [DPG], y
    ld   [R5], x
    ld   ac, [y,x]
    ld   [SPG], y
    ld   [T6], x
    ld   [y,x], ac
    ld   [DPG], y
    ld   [R6], x
    ld   ac, [y,x]
    ld   [SPG], y
    ld   [T7], x
    ld   [y,x], ac
    ld   [DPG], y
    ld   [R7], x
    ld   ac, [y,x]
    ld   [SPG], ac
    add  2, ac
    ld   ac, [SPG]
    ld   [DPG], ac
    add  2, ac
    ld   ac, [DPG]
    ld   [W4], ac
    dec
    ld   ac, [W4]
    bne  rcr_col
    ld   0x50, y
    ld   MAP_RUN, [y,x]
    ld   rc_back >> 8, y
    jmp  rc_back
vr_ram:                         ; W6 = the page, X = the low byte (the map write keeps X)
    ld   0x50, y
    ld   0xFF, [y,x]
    ld   [W6], y
    ld   [y,x], ac
    ld   0x50, y
    ld   MAP_RUN, [y,x]
    ld   vr_back >> 8, y
    jmp  vr_back
rc_end:

; ============================================================
; the bytecode
; ============================================================
; ============================================================
; made by vmc.py from basic.vm: change that file
; ============================================================

VM_P_EXIT = 0
VM_P_LIT8 = 1
VM_P_LIT16 = 2
VM_P_BR = 3
VM_P_0BR = 4
VM_P_LBR = 5
VM_P_L0BR = 6
VM_P_SLIT = 7
VM_P_ZPAT = 8
VM_P_ZPST = 9
VM_P_ZPCAT = 10
VM_P_ZPCST = 11
VM_P_DUP = 12
VM_P_DROP = 13
VM_P_SWAP = 14
VM_P_OVER = 15
VM_P_NIP = 16
VM_P_ROT = 17
VM_P_2DUP = 18
VM_P_TOR = 19
VM_P_RFROM = 20
VM_P_RAT = 21
VM_P_RDROP = 22
VM_P_AT = 23
VM_P_STORE = 24
VM_P_CAT = 25
VM_P_CSTORE = 26
VM_P_ADD = 27
VM_P_SUB = 28
VM_P_AND = 29
VM_P_OR = 30
VM_P_XOR = 31
VM_P_INVERT = 32
VM_P_INC = 33
VM_P_DEC = 34
VM_P_2MUL = 35
VM_P_2DIV = 36
VM_P_EQ = 37
VM_P_ULT = 38
VM_P_LT = 39
VM_P_0EQ = 40
VM_P_0LT = 41
VM_P_MUL = 42
VM_P_UMOD = 43
VM_P_EXECUTE = 44
VM_P_CMOVE = 45
VM_P_CMOVEU = 46
VM_P_FILL = 47
VM_P_SYS = 48
VM_P_CH = 49
VM_P_NUM = 50
VM_P_TPINC = 51
VM_P_POLL = 52
VM_P_RESET = 53
VM_P_GLYPH = 54
VM_P_ROWCPY = 55
VM_P_VPLOT = 56
VM_P_DIGQ = 57
VM_P_ALPHQ = 58
VM_P_FINDVAR = 59
VM_P_VARNAME = 60

w_KWTAB:
    #d8 69, 78, 196, 70, 79, 210, 78, 69, 88, 212, 68, 65
    #d8 84, 193, 73, 78, 80, 85, 212, 68, 73, 205, 82, 69
    #d8 65, 196, 76, 69, 212, 71, 79, 84, 207, 82, 85, 206
    #d8 73, 198, 82, 69, 83, 84, 79, 82, 197, 71, 79, 83
    #d8 85, 194, 82, 69, 84, 85, 82, 206, 82, 69, 205, 83
    #d8 84, 79, 208, 79, 206, 80, 82, 73, 78, 212, 76, 73
    #d8 83, 212, 67, 76, 69, 65, 210, 78, 69, 215, 67, 79
    #d8 78, 212, 80, 79, 75, 197, 67, 65, 76, 204, 67, 76
    #d8 211, 76, 79, 67, 65, 84, 197, 84, 73, 78, 212, 84
    #d8 69, 88, 212, 77, 79, 68, 197, 80, 76, 79, 212, 76
    #d8 73, 78, 197, 83, 67, 65, 206, 66, 69, 69, 208, 83
    #d8 79, 85, 78, 196, 78, 79, 73, 83, 197, 87, 65, 73
    #d8 212, 76, 79, 65, 196, 83, 65, 86, 197, 68, 73, 210
    #d8 68, 69, 204, 68, 79, 211, 71, 69, 212, 84, 207, 83
    #d8 84, 69, 208, 84, 72, 69, 206, 65, 78, 196, 79, 210
    #d8 78, 79, 212, 77, 79, 196, 65, 66, 211, 82, 78, 196
    #d8 80, 69, 69, 203, 83, 71, 206, 70, 82, 197, 73, 78
    #d8 75, 69, 217, 80, 65, 196, 76, 69, 206, 65, 83, 195
    #d8 86, 65, 204, 67, 72, 82, 164, 83, 84, 82, 164, 76
    #d8 69, 70, 84, 164, 77, 73, 68, 164, 82, 73, 71, 72
    #d8 84, 164, 72, 69, 88, 164, 84, 65, 194, 0
w_ERRTAB:
    #d8 6, 83, 121, 110, 116, 97, 120, 13, 79, 117, 116, 32
    #d8 111, 102, 32, 109, 101, 109, 111, 114, 121, 14, 85, 110
    #d8 100, 101, 102, 105, 110, 101, 100, 32, 108, 105, 110, 101
    #d8 13, 84, 121, 112, 101, 32, 109, 105, 115, 109, 97, 116
    #d8 99, 104, 16, 68, 105, 118, 105, 115, 105, 111, 110, 32
    #d8 98, 121, 32, 122, 101, 114, 111, 20, 82, 69, 84, 85
    #d8 82, 78, 32, 119, 105, 116, 104, 111, 117, 116, 32, 71
    #d8 79, 83, 85, 66, 16, 78, 69, 88, 84, 32, 119, 105
    #d8 116, 104, 111, 117, 116, 32, 70, 79, 82, 11, 79, 117
    #d8 116, 32, 111, 102, 32, 100, 97, 116, 97, 13, 66, 97
    #d8 100, 32, 115, 117, 98, 115, 99, 114, 105, 112, 116, 16
    #d8 73, 108, 108, 101, 103, 97, 108, 32, 113, 117, 97, 110
    #d8 116, 105, 116, 121, 15, 83, 116, 114, 105, 110, 103, 32
    #d8 116, 111, 111, 32, 108, 111, 110, 103, 14, 67, 97, 110
    #d8 39, 116, 32, 99, 111, 110, 116, 105, 110, 117, 101, 13
    #d8 82, 101, 100, 105, 109, 39, 100, 32, 97, 114, 114, 97
    #d8 121, 5, 66, 114, 101, 97, 107, 14, 73, 108, 108, 101
    #d8 103, 97, 108, 32, 100, 105, 114, 101, 99, 116, 6, 76
    #d8 97, 121, 111, 117, 116, 4, 70, 105, 108, 101
w_SASSIGN:
    #d8 12, 25, 40, 4, 6, 13, 1, 0, 14, 24, 0, 12
    #d8 8, 60, 2, 0, 30, w_WITHIN >> 8, w_WITHIN & 0xFF, 4, 2, w_TMPCOPY >> 8, w_TMPCOPY & 0xFF, 12
    #d8 25, 1, 4, 27, 12, w_ROOM >> 8, w_ROOM & 0xFF, 8, 60, 14, 28, 12
    #d8 9, 60, 18, 15, 25, 33, 45, 14, 25, 15, 27, 33
    #d8 15, 25, 15, 26, 33, 1, 2, w_PICK >> 8, w_PICK & 0xFF, 14, 24, 14
    #d8 24, 0

#addr 0xFC00
    #d8 MODE_32K


; ============================================================
; power_up - the boot loader comes here with map 05
; ============================================================
