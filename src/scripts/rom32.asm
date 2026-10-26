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


#addr 0x8200
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


#addr 0x8300
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


#addr 0x8400
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


#addr 0x8500
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
; BASIC (vector x8024) - for now a placeholder: BASIC is being designed
; (docs/BASIC.md); Esc goes to the DOS when there is one
; ============================================================


#addr 0x8600
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


#addr 0xA000
basic:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   MAP_RUN, ac
    ld   ac, [MAP_SHADOW]
    ld   0x50, y
    ld   MAP_RUN, [y,x]
    ld   LINK_LO, x             ; CALL lib_ram_copy
    ld   rom_r32, [x]
    ld   LINK_HI, x
    ld   rom_r32 >> 8, [x]
    ld   lib_ram_copy >> 8, y
    jmp  lib_ram_copy
rom_r32:
    ld   LINK_LO, x             ; CALL port_init
    ld   rom_r33, [x]
    ld   LINK_HI, x
    ld   rom_r33 >> 8, [x]
    ld   port_init >> 8, y
    jmp  port_init
rom_r33:
    ld   LINK_LO, x             ; CALL con_clear
    ld   rom_r34, [x]
    ld   LINK_HI, x
    ld   rom_r34 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
rom_r34:
    ld   s_bas1 & 0xFF, ac
    ld   ac, [R0]
    ld   s_bas1 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   rom_r35, [x]
    ld   LINK_HI, x
    ld   rom_r35 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
rom_r35:
    ld   2, ac
    ld   ac, [CUR_ROW]
    clr  ac
    ld   ac, [CUR_COL]
    ld   s_bas2 & 0xFF, ac
    ld   ac, [R0]
    ld   s_bas2 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   rom_r36, [x]
    ld   LINK_HI, x
    ld   rom_r36 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
rom_r36:
    ld   [KBD_HEAD], ac         ; forget the keys pressed meanwhile
    ld   ac, [KBD_TAIL]
bs_loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames_io
    ld   rom_r37, [x]
    ld   LINK_HI, x
    ld   rom_r37 >> 8, [x]
    ld   wait_frames_io >> 8, y
    jmp  wait_frames_io
rom_r37:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   rom_r38, [x]
    ld   LINK_HI, x
    ld   rom_r38 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
rom_r38:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   rom_r39, [x]
    ld   LINK_HI, x
    ld   rom_r39 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
rom_r39:
    xor  0x1B, ac               ; Esc: the DOS
    bne  bs_loop
    ld   MENU_BLK >> 8, y
    ld   MB_PARENT, x
    ld   0, [y,x]
    ld   dos_back >> 8, y
    jmp  dos_back

s_bas1:     #d "PLACARD BASIC", 0x00
s_bas2:     #d "BASIC is not written yet.  Esc: the DOS (DOS.PLC on the SD card)", 0x00

#addr 0xFC00
    #d8 MODE_32K


; ============================================================
; power_up - the boot loader comes here with map 05
; ============================================================
