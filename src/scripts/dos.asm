; ============================================================
; made by asm_expand.py from dos.masm: change that file, then run
;     python3 asm_expand.py dos.masm
; ============================================================

; ============================================================
; dos.masm - the Placard DOS: a file browser that loads, runs and saves
; programs on the SD card (the 32K ROM image)
; ============================================================
;
; The DOS is the program in the ROM (docs/DOS.md, docs/ROM.md "The 32K
; image").  The boot loader (BOOT_MODE = 02) jumps to DOS_START with map
; 05; the DOS runs with map 07 (RAM x0000-x5FFF, the DOS and the library
; in ROM x8000-xFFFF) and shows the SD card's files:
;
;   power-up     "PLACARD DOS", then about a second in which Esc held on the
;                keyboard goes straight to the browser.  Otherwise BOOT.CFG
;                in the root folder names the program to run (one short
;                name, "MENU.PLC"), and the browser comes when it is
;                missing or the program comes back.
;   browser      the current folder's entries, the chosen one on a blue bar.
;                Up / Down move; Enter runs a .PLC file or opens a folder;
;                Backspace goes to the folder above; Del deletes the file;
;                B writes BOOT.CFG = the chosen file (root folder only); R
;                reads the folder again (a changed card); Esc gives a
;                command line:
;                  RUN name            run a .PLC file
;                  LOAD name hhhh      load a file's bytes at a hex address
;                  SAVE name hhhh hhhh [hhhh]
;                                      save memory (start, length, entry =
;                                      start) as a .PLC file (gen_plc.py
;                                      has the header; start 0000 makes a
;                                      RAM image, else a library program)
;                  DEL name, CD name, BOOT name (writes BOOT.CFG), DIR
;   a program    a .PLC file: 16-byte header ("PLC", type, load address,
;                length, entry), then the bytes.  Type 0, a library
;                program, is copied to its load address (x0100-x3FFF) and
;                entered with map 07, SP = FF, LIB_RAM in place; it comes
;                back by jumping to the DOS vector x8008.  Type 1, a RAM
;                image (the older demos), is copied to RAM x0000-x49FF and
;                started at x0000 with map FF through MB_GO (menu block, as
;                the demo menu ROM did); it comes back through MB_EXIT.
;                The menu block (placard_menu.asm) carries "MNU", MB_MODE
;                = 1 (no time limit), so a program's menu_poll / hook
;                leaves on Esc.
;
; DOS VECTORS (x8000-x80FF), the fixed places a program may jump to or
; CALL whatever the DOS's code looks like later:
;   x8000  the reset code (nop, jump to the boot loader): a 32K cartridge
;          reads it at x0000
;   x8008  dos_back    jump here when a program is done (map with section
;                      4 ROM: 05 or 07); the DOS starts again, re-reads the
;                      card, runs MB_PARENT if a program set it (a menu
;                      program names itself there to be run again), else
;                      shows the browser
;   x800C  dos_run     R1:R0 = "NAME.PLC", 0 in RAM: the DOS loads and
;                      runs it (never returns; see dos_back for coming back)
;   x8010  fs_create   x8014 fs_write   x8018 fs_close   x801C fs_delete
;   x8020  fs_save     the FAT writer (placard_fsw.masm): CALL as a library
;                      routine, e.g.  ld 0x80, y / jmp 0x20  with LINK set
;
; RAM: zero page x20-x5F (the DOS's variables), DOS_DIR x4000-x47FF (the
; folder: 128 entries of 16 bytes: name 11, attributes, size 4), DOS_LINE
; x4800 (the command line), DOS_BUF x5400-x55FF and DOS_BUF0 x5600-x57FF
; (sectors while loading, saving and reading BOOT.CFG), the menu block
; x5D00-x5D6F (MB_CHILD, MB_PARENT, MB_DCLUS and the folder's name added),
; and FS_VARS / FS_BUF x4D00-x4FFF (placard_fs.asm).  A program must keep
; x4D00-x4FFF and the menu block as they are if it wants dos_run to find
; the same folder; the DOS mounts the card again when it comes back anyway.
;
; ROM: x8000-x80FF vectors, x8100-x9EFF this code (asm_expand.py pages
; it), x9F00-x9FFF LIB_RAM's image (the boot reads it at x1F00 on a 32K
; cartridge), xA000-xAFFF free (the monitor), xB000-xBFFF the FAT writer.
;
;     python3 asm_expand.py dos.masm          writes dos.asm
;     python3 placard_sim.py dos.asm          checks the image (build_rom)
;     python3 test_dos.py                     runs it with a card image
;
; Date: 10/26/2026
; ============================================================

#include "placard.asm"
#include "placard_lib.asm"
#include "placard_fsw.asm"

DOS_CODE  = 0x8100      ; this code, up to LIB_RAM's image
DOS_TOP   = 0x9F00
BOOT      = 0xFD00      ; rom_boot.asm: the boot loader (its reset code jumps here)
BOOT_MODE = 0xFC00      ; the boot mode byte: 02 = the DOS
MODE_DOS  = 0x02
MAP_DOS   = 0x07        ; sections 0-2 RAM, 3-7 ROM
LIB_RAM_IMG = 0x9F00    ; LIB_RAM's bytes in the 32K image

DOS_DIR   = 0x4000      ; the folder read: 128 entries x 16 bytes
DIR_MAX   = 128
DOS_LINE  = 0x4800      ; the command line (con_gets)
DOS_BUF   = 0x5400      ; a sector: the program file's first, BOOT.CFG
DOS_BUF0  = 0x5600      ; a RAM image's page 0 until the DOS lets go of the zero page
MODE_BASE = 0x5A20      ; mode byte of pixel row 0 (bits 6:4 = tint)
TINT_BAR  = 0x40        ; the chosen entry: a blue bar

; MB_CHILD, MB_PARENT, MB_DCLUS, MB_FNAME: the menu block, placard_menu.asm

LIST_ROW  = 2           ; text rows of the list
LIST_N    = 50
HELP_ROW  = 53
MSG_ROW   = 55
CMD_ROW   = 57
ESC_FRAMES = 60         ; about a second to hold Esc at power-up

; zero page
d_n     = 0x20          ; entries in DOS_DIR
d_sel   = 0x21          ; the chosen entry
d_top   = 0x22          ; the first entry shown
d_i     = 0x23          ; draw_list: the entry
d_row   = 0x24          ;   and its text row
d_pl    = 0x25          ; the entry's address in DOS_DIR (dir_ptr)
d_ph    = 0x26
d_t     = 0x27          ; scratch
d_t2    = 0x28
d_el    = 0x29          ; the program's entry
d_eh    = 0x2A
d_ll    = 0x2B          ; its load address (SAVE: the next source byte)
d_lh    = 0x2C
d_cl    = 0x2D          ; its length (SAVE: bytes still to write)
d_ch    = 0x2E
d_type  = 0x2F          ; its type
d_esc   = 0x30          ; 1 = Esc was held at power-up
d_ml    = 0x31          ; bar_set: the row's first mode byte
d_mh    = 0x32
d_al    = 0x33          ; hex4: the value (SAVE: the file's size)
d_ah    = 0x34
d_pos   = 0x35          ; the command line: next character
d_len   = 0x36          ; word / hex4: characters taken
d_k     = 0x37          ; the key
d_c     = 0x38          ; a character
d_msgl  = 0x39          ; the message to show (0 = none)
d_msgh  = 0x3A
d_err   = 0x3B          ; the error code shown after it (0 = none)
d_name  = 0x40          ; 13: a name, "NAME.EXT", 0

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


#addr 0x8100
dos_start:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   MAP_DOS, ac
    ld   ac, [MAP_SHADOW]
    ld   0x50, y
    ld   MAP_DOS, [y,x]         ; map 07 (section 4, this code, stays ROM)
    ld   ds_block >> 8, y
    jmp  ds_block

ds_block:
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
    ld   0x1F, ac               ; x5D11-x5D1F (a menu program's marks) = 0
    ld   ac, [d_t]
ds_z:
    ld   [d_t], x
    ld   0, [y,x]
    ld   [d_t], ac
    dec
    ld   ac, [d_t]
    xor  0x10, ac
    bne  ds_z
    clr  ac                     ; MB_EXIT and MB_GO code into the RAM
    ld   ac, [d_t]
ds_cp:
    ld   [d_t], ac
    add  stubs & 0xFF, x
    ld   stubs >> 8, y
    ld   [y,x], ac
    ld   ac, [d_t2]
    ld   [d_t], ac
    add  MB_EXIT, x
    ld   MENU_BLK >> 8, y
    ld   [d_t2], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    inc
    ld   ac, [d_t]
    xor  16, ac
    bne  ds_cp
    clr  ac
    ld   ac, [d_msgh]
    ld   ac, [d_err]
    ld   ac, [d_sel]
    ld   ac, [d_top]
    ld   ds_title >> 8, y
    jmp  ds_title

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

ds_card:
    ld   LINK_LO, x             ; CALL mount
    ld   dos_r7, [x]
    ld   LINK_HI, x
    ld   dos_r7 >> 8, [x]
    ld   mount >> 8, y
    jmp  mount
dos_r7:
    beq  ds_c1
    ld   browser >> 8, y        ; dir_read tries again and says so
    jmp  browser
ds_c1:
    ld   [d_esc], ac
    bne  ds_browse
    ld   s_cfg & 0xFF, ac       ; BOOT.CFG into DOS_BUF
    ld   ac, [R0]
    ld   s_cfg >> 8, ac
    ld   ac, [R1]
    ld   DOS_BUF & 0xFF, ac
    ld   ac, [R4]
    ld   DOS_BUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_load
    ld   dos_r8, [x]
    ld   LINK_HI, x
    ld   dos_r8 >> 8, [x]
    ld   fs_load >> 8, y
    jmp  fs_load
dos_r8:
    bne  ds_browse
    clr  ac                     ; MB_CHILD = its first word
    ld   ac, [d_t]
ds_cfg:
    ld   DOS_BUF >> 8, y
    ld   [d_t], x
    ld   [y,x], ac
    sub  0x21, ac
    blt  ds_cfge                ; space, CR, LF, 00: the end
    add  0x21, ac
    ld   ac, [d_c]
    ld   [d_t], ac
    add  MB_CHILD, x
    ld   MENU_BLK >> 8, y
    ld   [d_c], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    inc
    ld   ac, [d_t]
    xor  12, ac
    bne  ds_cfg
ds_cfge:
    ld   [d_t], ac
    add  MB_CHILD, x
    ld   MENU_BLK >> 8, y
    ld   0, [y,x]
    ld   [d_t], ac
    beq  ds_browse              ; an empty file
    ld   run_child >> 8, y
    jmp  run_child
ds_browse:
    ld   browser >> 8, y
    jmp  browser

; ============================================================
; dos_run (vector x800C) - run the file named at R1:R0
; dos_back (vector x8008) - a program is done
; ============================================================

#addr 0x8200
ds_title:
    ld   LINK_LO, x             ; CALL con_clear
    ld   dos_r1, [x]
    ld   LINK_HI, x
    ld   dos_r1 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
dos_r1:
    ld   s_title & 0xFF, ac
    ld   ac, [R0]
    ld   s_title >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r2, [x]
    ld   LINK_HI, x
    ld   dos_r2 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r2:
    ld   2, ac
    ld   ac, [CUR_ROW]
    clr  ac
    ld   ac, [CUR_COL]
    ld   s_hold & 0xFF, ac
    ld   ac, [R0]
    ld   s_hold >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r3, [x]
    ld   LINK_HI, x
    ld   dos_r3 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r3:
    ld   LINK_LO, x             ; CALL port_init
    ld   dos_r4, [x]
    ld   LINK_HI, x
    ld   dos_r4 >> 8, [x]
    ld   port_init >> 8, y
    jmp  port_init
dos_r4:
    clr  ac
    ld   ac, [d_esc]
    ld   ESC_FRAMES, ac
    ld   ac, [d_t2]
ds_w:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames_io
    ld   dos_r5, [x]
    ld   LINK_HI, x
    ld   dos_r5 >> 8, [x]
    ld   wait_frames_io >> 8, y
    jmp  wait_frames_io
dos_r5:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   dos_r6, [x]
    ld   LINK_HI, x
    ld   dos_r6 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
dos_r6:
    ld   [KBD_NOW], ac          ; Esc is key 0: column 0, bit 0, 0 = down
    and  1, ac
    bne  ds_w1
    ld   1, ac
    ld   ac, [d_esc]
ds_w1:
    ld   [d_t2], ac
    dec
    ld   ac, [d_t2]
    bne  ds_w
    ld   [KBD_HEAD], ac         ; forget the keys pressed meanwhile
    ld   ac, [KBD_TAIL]
    ld   ds_card >> 8, y
    jmp  ds_card

dos_run:
    clr  ac
    ld   ac, [d_t]
dr_cp:
    ld   [R1], y
    ld   [R0], x
    ld   [y,x], ac
    ld   ac, [d_c]
    ld   [d_t], ac
    add  MB_CHILD, x
    ld   MENU_BLK >> 8, y
    ld   [d_c], ac
    ld   ac, [y,x]
    beq  dr_go
    ld   [d_t], ac
    inc
    ld   ac, [d_t]
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
    ld   LINK_LO, x             ; CALL dos_reinit
    ld   dos_r9, [x]
    ld   LINK_HI, x
    ld   dos_r9 >> 8, [x]
    ld   dos_reinit >> 8, y
    jmp  dos_reinit
dos_r9:
    ld   run_child >> 8, y
    jmp  run_child

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
    ld   dos_r14, [x]
    ld   LINK_HI, x
    ld   dos_r14 >> 8, [x]
    ld   sd_init >> 8, y
    jmp  sd_init
dos_r14:
    bne  m_x
    ld   LINK_LO, x             ; CALL fs_mount
    ld   dos_r15, [x]
    ld   LINK_HI, x
    ld   dos_r15 >> 8, [x]
    ld   fs_mount >> 8, y
    jmp  fs_mount
dos_r15:
m_x:
    ld   lib_leave >> 8, y
    jmp  lib_leave


#addr 0x8300
dos_back:
    ld   LINK_LO, x             ; CALL dos_reinit
    ld   dos_r10, [x]
    ld   LINK_HI, x
    ld   dos_r10 >> 8, [x]
    ld   dos_reinit >> 8, y
    jmp  dos_reinit
dos_r10:
    ld   MENU_BLK >> 8, y
    ld   MB_PARENT, x
    ld   [y,x], ac
    beq  db_browse
    ld   12, ac                 ; the parent runs again: MB_CHILD = MB_PARENT
    ld   ac, [d_t]
db_cp:
    ld   [d_t], ac
    add  MB_PARENT, x
    ld   MENU_BLK >> 8, y
    ld   [y,x], ac
    ld   ac, [d_c]
    ld   [d_t], ac
    add  MB_CHILD, x
    ld   [d_c], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    sub  1, ac
    ld   ac, [d_t]
    bcc  db_cp                  ; no borrow: more to copy
    ld   MB_PARENT, x
    ld   0, [y,x]
    ld   run_child >> 8, y
    jmp  run_child
db_browse:
    clr  ac
    ld   ac, [d_sel]
    ld   ac, [d_top]
    ld   browser >> 8, y
    jmp  browser

        ; the port, the card, the folder it was in
dos_reinit:
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
    ld   MAP_DOS, ac
    ld   ac, [MAP_SHADOW]
    ld   0x50, y
    ld   MAP_DOS, [y,x]
    clr  ac
    ld   ac, [d_msgh]
    ld   ac, [d_err]
    ld   LINK_LO, x             ; CALL lib_ram_copy
    ld   dos_r11, [x]
    ld   LINK_HI, x
    ld   dos_r11 >> 8, [x]
    ld   lib_ram_copy >> 8, y
    jmp  lib_ram_copy
dos_r11:
    ld   LINK_LO, x             ; CALL port_init
    ld   dos_r12, [x]
    ld   LINK_HI, x
    ld   dos_r12 >> 8, [x]
    ld   port_init >> 8, y
    jmp  port_init
dos_r12:
    ld   LINK_LO, x             ; CALL mount
    ld   dos_r13, [x]
    ld   LINK_HI, x
    ld   dos_r13 >> 8, [x]
    ld   mount >> 8, y
    jmp  mount
dos_r13:
    beq  dri_ok
    ld   lib_leave >> 8, y      ; dir_read tries again and says so
    jmp  lib_leave
dri_ok:
    ld   3, ac                  ; V_DCLUS = MB_DCLUS: the folder
    ld   ac, [d_t]
dri_cp:
    ld   [d_t], ac
    add  MB_DCLUS, x
    ld   MENU_BLK >> 8, y
    ld   [y,x], ac
    ld   ac, [d_c]
    ld   [d_t], ac
    add  V_DCLUS, x
    ld   FSV, y
    ld   [d_c], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    sub  1, ac
    ld   ac, [d_t]
    bcc  dri_cp
    ld   lib_leave >> 8, y
    jmp  lib_leave

lib_ram_copy:
    clr  ac
    ld   ac, [d_t]
lrc:
    ld   [d_t], x
    ld   LIB_RAM_IMG >> 8, y
    ld   [y,x], ac
    ld   LIB_RAM >> 8, y
    ld   ac, [y,x]
    ld   [d_t], ac
    inc
    ld   ac, [d_t]
    bne  lrc
    ld   [LINK_HI], y
    jmp  [LINK_LO]

save_dclus:
    ld   3, ac
    ld   ac, [d_t]
sd_cp:
    ld   [d_t], ac
    add  V_DCLUS, x
    ld   FSV, y
    ld   [y,x], ac
    ld   ac, [d_c]
    ld   [d_t], ac
    add  MB_DCLUS, x
    ld   MENU_BLK >> 8, y
    ld   [d_c], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    sub  1, ac
    ld   ac, [d_t]
    bcc  sd_cp
    ld   [LINK_HI], y
    jmp  [LINK_LO]

dclus_zero:
    ld   FSV, y
    ld   V_DCLUS, x
    ld   [y,x], ac
    ld   V_DCLUS + 1, x
    or   [y,x], ac
    ld   V_DCLUS + 2, x
    or   [y,x], ac
    ld   V_DCLUS + 3, x
    or   [y,x], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; run_child - load and run the program named at MB_CHILD
; ============================================================

#addr 0x8400
run_child:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   MB_CHILD, ac
    ld   ac, [R0]
    ld   MENU_BLK >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   dos_r16, [x]
    ld   LINK_HI, x
    ld   dos_r16 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
dos_r16:
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
    ld   dos_r17, [x]
    ld   LINK_HI, x
    ld   dos_r17 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
dos_r17:
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
    ld   s_notprog & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_notprog >> 8, ac
    ld   ac, [d_msgh]
    ld   browser >> 8, y
    jmp  browser
rc_dir:
    ld   s_isdir & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_isdir >> 8, ac
    ld   ac, [d_msgh]
    ld   browser >> 8, y
    jmp  browser
rc_err:
    ld   fail >> 8, y
    jmp  fail

rc_header:
    ld   DOS_BUF >> 8, y
    ld   3, x
    ld   [y,x], ac
    ld   ac, [d_type]
    ld   4, x
    ld   [y,x], ac
    ld   ac, [d_ll]
    ld   5, x
    ld   [y,x], ac
    ld   ac, [d_lh]
    ld   6, x
    ld   [y,x], ac
    ld   ac, [d_cl]
    ld   7, x
    ld   [y,x], ac
    ld   ac, [d_ch]
    ld   8, x
    ld   [y,x], ac
    ld   ac, [d_el]
    ld   9, x
    ld   [y,x], ac
    ld   ac, [d_eh]
    ld   [d_type], ac
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
; the browser
; ============================================================
k_up:
    ld   [d_sel], ac
    beq  ku_none
    clr  ac
    ld   LINK_LO, x             ; CALL bar_set
    ld   dos_r32, [x]
    ld   LINK_HI, x
    ld   dos_r32 >> 8, [x]
    ld   bar_set >> 8, y
    jmp  bar_set
dos_r32:
    ld   [d_sel], ac
    dec
    ld   ac, [d_sel]
    sub  [d_top], ac
    bcs  ku_scroll              ; above the screen
    ld   TINT_BAR, ac
    ld   LINK_LO, x             ; CALL bar_set
    ld   dos_r33, [x]
    ld   LINK_HI, x
    ld   dos_r33 >> 8, [x]
    ld   bar_set >> 8, y
    jmp  bar_set
dos_r33:
ku_none:
    ld   br_loop >> 8, y
    jmp  br_loop
ku_scroll:
    ld   [d_sel], ac
    ld   ac, [d_top]
    ld   br_draw >> 8, y
    jmp  br_draw

load_t0:
    ld   (DOS_BUF & 0xFF) + 16, ac    ; the 496 bytes after the header
    ld   ac, [R0]
    ld   DOS_BUF >> 8, ac
    ld   ac, [R1]
    ld   [d_ll], ac
    ld   ac, [R2]
    ld   [d_lh], ac
    ld   ac, [R3]
    clr  ac
    ld   ac, [R4]
    ld   LINK_LO, x             ; CALL memcpy
    ld   dos_r18, [x]
    ld   LINK_HI, x
    ld   dos_r18 >> 8, [x]
    ld   memcpy >> 8, y
    jmp  memcpy
dos_r18:
    ld   240, ac
    ld   ac, [R4]
    ld   LINK_LO, x             ; CALL memcpy
    ld   dos_r19, [x]
    ld   LINK_HI, x
    ld   dos_r19 >> 8, [x]
    ld   memcpy >> 8, y
    jmp  memcpy
dos_r19:
    ld   [R2], ac               ; the rest straight to load + 496 on
    ld   ac, [R4]
    ld   [R3], ac
    ld   ac, [R5]
lt0_rd:
    ld   LINK_LO, x             ; CALL fs_read
    ld   dos_r20, [x]
    ld   LINK_HI, x
    ld   dos_r20 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
dos_r20:
    beq  lt0_rd
    xor  1, ac                  ; 1: the end
    bne  lt0_err
    ld   LINK_LO, x             ; a program over x1F00 is fine
    ld   dos_r21, [x]
    ld   LINK_HI, x
    ld   dos_r21 >> 8, [x]
    ld   lib_ram_copy >> 8, y
    jmp  lib_ram_copy
dos_r21:
    ld   LINK_LO, x             ; CALL save_dclus
    ld   dos_r22, [x]
    ld   LINK_HI, x
    ld   dos_r22 >> 8, [x]
    ld   save_dclus >> 8, y
    jmp  save_dclus
dos_r22:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   [d_eh], y
    jmp  [d_el]
lt0_err:
    xor  1, ac
    ld   fail >> 8, y
    jmp  fail

        ; page 0 last, then map FF and x0000 through MB_GO
load_t1:
    ld   1, ac
    ld   ac, [d_t]
lt1_z:
    ld   [d_t], y
    clr  ac
lt1_z2:
    ld   ac, x
    ld   0, [y,x]
    inc
    bne  lt1_z2
    ld   [d_t], ac
    inc
    ld   ac, [d_t]
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
    ld   dos_r23, [x]
    ld   LINK_HI, x
    ld   dos_r23 >> 8, [x]
    ld   memcpy >> 8, y
    jmp  memcpy
dos_r23:
    clr  ac                     ; x0100-x01EF from the first sector
    ld   ac, [R2]
    ld   1, ac
    ld   ac, [R3]
    ld   240, ac
    ld   ac, [R4]
    ld   LINK_LO, x             ; CALL memcpy
    ld   dos_r24, [x]
    ld   LINK_HI, x
    ld   dos_r24 >> 8, [x]
    ld   memcpy >> 8, y
    jmp  memcpy
dos_r24:
    ld   0xF0, ac               ; the rest to x01F0 on
    ld   ac, [R4]
    ld   1, ac
    ld   ac, [R5]
lt1_rd:
    ld   LINK_LO, x             ; CALL fs_read
    ld   dos_r25, [x]
    ld   LINK_HI, x
    ld   dos_r25 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
dos_r25:
    beq  lt1_rd
    xor  1, ac
    bne  lt1_err
    ld   lt1_go >> 8, y
    jmp  lt1_go
lt1_err:
    xor  1, ac
    ld   fail >> 8, y
    jmp  fail

k_updir:
    ld   LINK_LO, x             ; CALL dclus_zero
    ld   dos_r38, [x]
    ld   LINK_HI, x
    ld   dos_r38 >> 8, [x]
    ld   dclus_zero >> 8, y
    jmp  dclus_zero
dos_r38:
    beq  kud_none
    ld   0x2E, ac               ; ".."
    ld   ac, [d_name]
    ld   ac, [d_name + 1]
    clr  ac
    ld   ac, [d_name + 2]
    ld   cd_name >> 8, y
    jmp  cd_name
kud_none:
    ld   br_loop >> 8, y
    jmp  br_loop


#addr 0x8600
browser:
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   LINK_LO, x             ; CALL dir_read
    ld   dos_r26, [x]
    ld   LINK_HI, x
    ld   dos_r26 >> 8, [x]
    ld   dir_read >> 8, y
    jmp  dir_read
dos_r26:
    ld   [d_n], ac              ; keep the choice on the list
    bne  br_c1
    ld   ac, [d_sel]
    ld   ac, [d_top]
    bra  br_c3
br_c1:
    ld   [d_sel], ac
    sub  [d_n], ac
    bcs  br_c2                  ; borrow: d_sel < d_n
    ld   [d_n], ac
    dec
    ld   ac, [d_sel]
br_c2:
    ld   [d_sel], ac
    sub  [d_top], ac
    bcs  br_c4                  ; d_sel < d_top
    sub  LIST_N, ac
    bcs  br_c3                  ; on the screen
    ld   [d_sel], ac
    sub  LIST_N - 1, ac
    ld   ac, [d_top]
    bra  br_c3
br_c4:
    ld   [d_sel], ac
    ld   ac, [d_top]
br_c3:
    ld   br_draw >> 8, y
    jmp  br_draw

br_draw:
    ld   LINK_LO, x             ; CALL draw_list
    ld   dos_r27, [x]
    ld   LINK_HI, x
    ld   dos_r27 >> 8, [x]
    ld   draw_list >> 8, y
    jmp  draw_list
dos_r27:
    ld   LINK_LO, x             ; CALL show_msg
    ld   dos_r28, [x]
    ld   LINK_HI, x
    ld   dos_r28 >> 8, [x]
    ld   show_msg >> 8, y
    jmp  show_msg
dos_r28:
br_loop:
    ld   1, ac
    ld   LINK_LO, x             ; CALL wait_frames_io
    ld   dos_r29, [x]
    ld   LINK_HI, x
    ld   dos_r29 >> 8, [x]
    ld   wait_frames_io >> 8, y
    jmp  wait_frames_io
dos_r29:
    ld   LINK_LO, x             ; CALL kbd_scan
    ld   dos_r30, [x]
    ld   LINK_HI, x
    ld   dos_r30 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
dos_r30:
    ld   LINK_LO, x             ; CALL kbd_getc
    ld   dos_r31, [x]
    ld   LINK_HI, x
    ld   dos_r31 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
dos_r31:
    beq  br_loop
    ld   ac, [d_k]
    ld   br_key >> 8, y
    jmp  br_key

br_key:
    ld   [d_k], ac
    xor  0x11, ac               ; Up
    bne  bk_1
    ld   k_up >> 8, y
    jmp  k_up
bk_1:
    ld   [d_k], ac
    xor  0x12, ac               ; Down
    bne  bk_2
    ld   k_down >> 8, y
    jmp  k_down
bk_2:
    ld   [d_k], ac
    xor  0x0A, ac               ; Enter
    bne  bk_3
    ld   k_enter >> 8, y
    jmp  k_enter
bk_3:
    ld   [d_k], ac
    xor  0x08, ac               ; Backspace
    bne  bk_4
    ld   k_updir >> 8, y
    jmp  k_updir
bk_4:
    ld   [d_k], ac
    xor  0x7F, ac               ; Delete
    bne  bk_5
    ld   k_del >> 8, y
    jmp  k_del
bk_5:
    ld   [d_k], ac
    and  0xDF, ac               ; b or B
    xor  0x42, ac
    bne  bk_6
    ld   k_boot >> 8, y
    jmp  k_boot
bk_6:
    ld   [d_k], ac
    and  0xDF, ac               ; r or R
    xor  0x52, ac
    bne  bk_7
    ld   browser >> 8, y
    jmp  browser
bk_7:
    ld   [d_k], ac
    xor  0x1B, ac               ; Esc
    bne  bk_8
    ld   k_cmd >> 8, y
    jmp  k_cmd
bk_8:
    ld   br_loop >> 8, y
    jmp  br_loop

fail:
    ld   ac, [d_err]
    ld   s_err & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_err >> 8, ac
    ld   ac, [d_msgh]
    ld   browser >> 8, y
    jmp  browser

; ============================================================
; the command line (Esc)
; ============================================================

#addr 0x8700
k_down:
    ld   [d_sel], ac
    inc
    sub  [d_n], ac
    bcc  kd_none                ; no borrow: the last one already
    clr  ac
    ld   LINK_LO, x             ; CALL bar_set
    ld   dos_r34, [x]
    ld   LINK_HI, x
    ld   dos_r34 >> 8, [x]
    ld   bar_set >> 8, y
    jmp  bar_set
dos_r34:
    ld   [d_sel], ac
    inc
    ld   ac, [d_sel]
    sub  [d_top], ac
    sub  LIST_N, ac
    bcc  kd_scroll              ; below the screen
    ld   TINT_BAR, ac
    ld   LINK_LO, x             ; CALL bar_set
    ld   dos_r35, [x]
    ld   LINK_HI, x
    ld   dos_r35 >> 8, [x]
    ld   bar_set >> 8, y
    jmp  bar_set
dos_r35:
kd_none:
    ld   br_loop >> 8, y
    jmp  br_loop
kd_scroll:
    ld   [d_sel], ac
    sub  LIST_N - 1, ac
    ld   ac, [d_top]
    ld   br_draw >> 8, y
    jmp  br_draw

k_enter:
    ld   [d_n], ac
    beq  ke_none
    ld   [d_sel], ac
    ld   LINK_LO, x             ; CALL dir_ptr
    ld   dos_r36, [x]
    ld   LINK_HI, x
    ld   dos_r36 >> 8, [x]
    ld   dir_ptr >> 8, y
    jmp  dir_ptr
dos_r36:
    ld   LINK_LO, x             ; CALL ent_name
    ld   dos_r37, [x]
    ld   LINK_HI, x
    ld   dos_r37 >> 8, [x]
    ld   ent_name >> 8, y
    jmp  ent_name
dos_r37:
    ld   [d_ph], y
    ld   [d_pl], ac
    add  11, x
    ld   [y,x], ac
    and  0x10, ac
    bne  ke_dir
    ld   [d_pl], ac             ; .PLC?
    add  8, x
    ld   [y,x], ac
    xor  0x50, ac
    bne  ke_notp
    ld   [d_pl], ac
    add  9, x
    ld   [y,x], ac
    xor  0x4C, ac
    bne  ke_notp
    ld   [d_pl], ac
    add  10, x
    ld   [y,x], ac
    xor  0x43, ac
    bne  ke_notp
    ld   run_name >> 8, y
    jmp  run_name
ke_notp:
    ld   s_notprog & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_notprog >> 8, ac
    ld   ac, [d_msgh]
    ld   br_draw >> 8, y
    jmp  br_draw
ke_dir:
    ld   cd_name >> 8, y
    jmp  cd_name
ke_none:
    ld   br_loop >> 8, y
    jmp  br_loop

k_del:
    ld   [d_n], ac
    beq  kdl_none
    ld   [d_sel], ac
    ld   LINK_LO, x             ; CALL dir_ptr
    ld   dos_r39, [x]
    ld   LINK_HI, x
    ld   dos_r39 >> 8, [x]
    ld   dir_ptr >> 8, y
    jmp  dir_ptr
dos_r39:
    ld   LINK_LO, x             ; CALL ent_name
    ld   dos_r40, [x]
    ld   LINK_HI, x
    ld   dos_r40 >> 8, [x]
    ld   ent_name >> 8, y
    jmp  ent_name
dos_r40:
    ld   d_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_delete
    ld   dos_r41, [x]
    ld   LINK_HI, x
    ld   dos_r41 >> 8, [x]
    ld   fs_delete >> 8, y
    jmp  fs_delete
dos_r41:
    bne  kdl_err
    ld   s_deleted & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_deleted >> 8, ac
    ld   ac, [d_msgh]
    ld   browser >> 8, y
    jmp  browser
kdl_err:
    ld   fail >> 8, y
    jmp  fail
kdl_none:
    ld   br_loop >> 8, y
    jmp  br_loop

c_run:
    ld   LINK_LO, x             ; CALL word
    ld   dos_r60, [x]
    ld   LINK_HI, x
    ld   dos_r60 >> 8, [x]
    ld   word >> 8, y
    jmp  word
dos_r60:
    beq  cr_name
    ld   run_name >> 8, y
    jmp  run_name
cr_name:
    ld   need_name >> 8, y
    jmp  need_name


#addr 0x8800
k_boot:
    ld   [d_n], ac
    beq  kbt_none
    ld   [d_sel], ac
    ld   LINK_LO, x             ; CALL dir_ptr
    ld   dos_r42, [x]
    ld   LINK_HI, x
    ld   dos_r42 >> 8, [x]
    ld   dir_ptr >> 8, y
    jmp  dir_ptr
dos_r42:
    ld   LINK_LO, x             ; CALL ent_name
    ld   dos_r43, [x]
    ld   LINK_HI, x
    ld   dos_r43 >> 8, [x]
    ld   ent_name >> 8, y
    jmp  ent_name
dos_r43:
    ld   boot_name >> 8, y
    jmp  boot_name
kbt_none:
    ld   br_loop >> 8, y
    jmp  br_loop

run_name:
    ld   12, ac
    ld   ac, [d_t]
rn_cp:
    ld   [d_t], ac
    add  d_name, x
    ld   [x], ac
    ld   ac, [d_c]
    ld   [d_t], ac
    add  MB_CHILD, x
    ld   MENU_BLK >> 8, y
    ld   [d_c], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    sub  1, ac
    ld   ac, [d_t]
    bcc  rn_cp
    ld   MB_MODE, x
    ld   1, [y,x]
    ld   MB_WHY, x
    ld   0, [y,x]
    ld   run_child >> 8, y
    jmp  run_child

cd_name:
    ld   d_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_open
    ld   dos_r44, [x]
    ld   LINK_HI, x
    ld   dos_r44 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
dos_r44:
    bne  cd_err
    ld   FSV, y                 ; a folder?
    ld   V_ENTRY + 11, x
    ld   [y,x], ac
    and  0x10, ac
    beq  cd_file
    ld   LINK_LO, x             ; CALL dclus_zero
    ld   dos_r45, [x]
    ld   LINK_HI, x
    ld   dos_r45 >> 8, [x]
    ld   dclus_zero >> 8, y
    jmp  dclus_zero
dos_r45:
    bne  cd_named
    ld   0x5C, ac               ; the root: "\"
    ld   ac, [d_name]
    clr  ac
    ld   ac, [d_name + 1]
cd_named:
    ld   12, ac                 ; MB_FNAME = d_name
    ld   ac, [d_t]
cd_cp:
    ld   [d_t], ac
    add  d_name, x
    ld   [x], ac
    ld   ac, [d_c]
    ld   [d_t], ac
    add  MB_FNAME, x
    ld   MENU_BLK >> 8, y
    ld   [d_c], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    sub  1, ac
    ld   ac, [d_t]
    bcc  cd_cp
    clr  ac
    ld   ac, [d_sel]
    ld   ac, [d_top]
    ld   browser >> 8, y
    jmp  browser
cd_file:
    ld   s_notdir & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_notdir >> 8, ac
    ld   ac, [d_msgh]
    ld   browser >> 8, y
    jmp  browser
cd_err:
    ld   fail >> 8, y
    jmp  fail

cmd_dispatch2:
    ld   s_boot & 0xFF, ac
    ld   ac, [R0]
    ld   s_boot >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL streq
    ld   dos_r58, [x]
    ld   LINK_HI, x
    ld   dos_r58 >> 8, [x]
    ld   streq >> 8, y
    jmp  streq
dos_r58:
    bne  cm_6
    ld   c_boot >> 8, y
    jmp  c_boot
cm_6:
    ld   s_dirc & 0xFF, ac
    ld   ac, [R0]
    ld   s_dirc >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL streq
    ld   dos_r59, [x]
    ld   LINK_HI, x
    ld   dos_r59 >> 8, [x]
    ld   streq >> 8, y
    jmp  streq
dos_r59:
    bne  cm_7
    ld   browser >> 8, y
    jmp  browser
cm_7:
    ld   s_unknown & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_unknown >> 8, ac
    ld   ac, [d_msgh]
    ld   br_draw >> 8, y
    jmp  br_draw


#addr 0x8900
boot_name:
    ld   LINK_LO, x             ; CALL dclus_zero
    ld   dos_r46, [x]
    ld   LINK_HI, x
    ld   dos_r46 >> 8, [x]
    ld   dclus_zero >> 8, y
    jmp  dclus_zero
dos_r46:
    bne  bn_root
    clr  ac                     ; DOS_BUF = the name, CR, LF
    ld   ac, [d_t]
bn_cp:
    ld   [d_t], ac
    add  d_name, x
    ld   [x], ac
    beq  bn_e
    ld   ac, [d_c]
    ld   [d_t], x
    ld   DOS_BUF >> 8, y
    ld   [d_c], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    inc
    ld   ac, [d_t]
    bra  bn_cp
bn_e:
    ld   [d_t], x
    ld   DOS_BUF >> 8, y
    ld   0x0D, [y,x]
    ld   [d_t], ac
    inc
    ld   ac, x
    ld   0x0A, [y,x]
    inc
    ld   ac, [R2]               ; the length
    clr  ac
    ld   ac, [R3]
    ld   s_cfg & 0xFF, ac
    ld   ac, [R0]
    ld   s_cfg >> 8, ac
    ld   ac, [R1]
    ld   DOS_BUF & 0xFF, ac
    ld   ac, [R4]
    ld   DOS_BUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_save
    ld   dos_r47, [x]
    ld   LINK_HI, x
    ld   dos_r47 >> 8, [x]
    ld   fs_save >> 8, y
    jmp  fs_save
dos_r47:
    bne  bn_err
    ld   s_boots & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_boots >> 8, ac
    ld   ac, [d_msgh]
    ld   browser >> 8, y
    jmp  browser
bn_root:
    ld   s_rootonly & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_rootonly >> 8, ac
    ld   ac, [d_msgh]
    ld   br_draw >> 8, y
    jmp  br_draw
bn_err:
    ld   fail >> 8, y
    jmp  fail

k_cmd:
    ld   CMD_ROW, ac
    ld   LINK_LO, x             ; CALL clr_row
    ld   dos_r48, [x]
    ld   LINK_HI, x
    ld   dos_r48 >> 8, [x]
    ld   clr_row >> 8, y
    jmp  clr_row
dos_r48:
    ld   CMD_ROW + 1, ac
    ld   LINK_LO, x             ; CALL clr_row
    ld   dos_r49, [x]
    ld   LINK_HI, x
    ld   dos_r49 >> 8, [x]
    ld   clr_row >> 8, y
    jmp  clr_row
dos_r49:
    ld   CMD_ROW, ac
    ld   ac, [CUR_ROW]
    clr  ac
    ld   ac, [CUR_COL]
    ld   s_prompt & 0xFF, ac
    ld   ac, [R0]
    ld   s_prompt >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r50, [x]
    ld   LINK_HI, x
    ld   dos_r50 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r50:
    ld   DOS_LINE & 0xFF, ac
    ld   ac, [R0]
    ld   DOS_LINE >> 8, ac
    ld   ac, [R1]
    ld   60, ac
    ld   ac, [R2]
    ld   LINK_LO, x             ; CALL con_gets
    ld   dos_r51, [x]
    ld   LINK_HI, x
    ld   dos_r51 >> 8, [x]
    ld   con_gets >> 8, y
    jmp  con_gets
dos_r51:
    clr  ac
    ld   ac, [d_pos]
    ld   LINK_LO, x             ; CALL word
    ld   dos_r52, [x]
    ld   LINK_HI, x
    ld   dos_r52 >> 8, [x]
    ld   word >> 8, y
    jmp  word
dos_r52:
    beq  kc_dir
    ld   cmd_dispatch >> 8, y
    jmp  cmd_dispatch
kc_dir:
    ld   browser >> 8, y
    jmp  browser

need_name:
    ld   s_name & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_name >> 8, ac
    ld   ac, [d_msgh]
    ld   br_draw >> 8, y
    jmp  br_draw
need_hex:
    ld   s_syntax & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_syntax >> 8, ac
    ld   ac, [d_msgh]
    ld   br_draw >> 8, y
    jmp  br_draw


#addr 0x8A00
cmd_dispatch:
    ld   s_run & 0xFF, ac
    ld   ac, [R0]
    ld   s_run >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL streq
    ld   dos_r53, [x]
    ld   LINK_HI, x
    ld   dos_r53 >> 8, [x]
    ld   streq >> 8, y
    jmp  streq
dos_r53:
    bne  cm_1
    ld   c_run >> 8, y
    jmp  c_run
cm_1:
    ld   s_load & 0xFF, ac
    ld   ac, [R0]
    ld   s_load >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL streq
    ld   dos_r54, [x]
    ld   LINK_HI, x
    ld   dos_r54 >> 8, [x]
    ld   streq >> 8, y
    jmp  streq
dos_r54:
    bne  cm_2
    ld   c_load >> 8, y
    jmp  c_load
cm_2:
    ld   s_save & 0xFF, ac
    ld   ac, [R0]
    ld   s_save >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL streq
    ld   dos_r55, [x]
    ld   LINK_HI, x
    ld   dos_r55 >> 8, [x]
    ld   streq >> 8, y
    jmp  streq
dos_r55:
    bne  cm_3
    ld   c_save >> 8, y
    jmp  c_save
cm_3:
    ld   s_del & 0xFF, ac
    ld   ac, [R0]
    ld   s_del >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL streq
    ld   dos_r56, [x]
    ld   LINK_HI, x
    ld   dos_r56 >> 8, [x]
    ld   streq >> 8, y
    jmp  streq
dos_r56:
    bne  cm_4
    ld   c_del >> 8, y
    jmp  c_del
cm_4:
    ld   s_cd & 0xFF, ac
    ld   ac, [R0]
    ld   s_cd >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL streq
    ld   dos_r57, [x]
    ld   LINK_HI, x
    ld   dos_r57 >> 8, [x]
    ld   streq >> 8, y
    jmp  streq
dos_r57:
    bne  cm_5
    ld   c_cd >> 8, y
    jmp  c_cd
cm_5:
    ld   cmd_dispatch2 >> 8, y
    jmp  cmd_dispatch2

c_del:
    ld   LINK_LO, x             ; CALL word
    ld   dos_r61, [x]
    ld   LINK_HI, x
    ld   dos_r61 >> 8, [x]
    ld   word >> 8, y
    jmp  word
dos_r61:
    beq  cdl_name
    ld   d_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_delete
    ld   dos_r62, [x]
    ld   LINK_HI, x
    ld   dos_r62 >> 8, [x]
    ld   fs_delete >> 8, y
    jmp  fs_delete
dos_r62:
    bne  cdl_err
    ld   s_deleted & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_deleted >> 8, ac
    ld   ac, [d_msgh]
    ld   browser >> 8, y
    jmp  browser
cdl_err:
    ld   fail >> 8, y
    jmp  fail
cdl_name:
    ld   need_name >> 8, y
    jmp  need_name
c_cd:
    ld   LINK_LO, x             ; CALL word
    ld   dos_r63, [x]
    ld   LINK_HI, x
    ld   dos_r63 >> 8, [x]
    ld   word >> 8, y
    jmp  word
dos_r63:
    beq  cdl_name
    ld   cd_name >> 8, y
    jmp  cd_name
c_boot:
    ld   LINK_LO, x             ; CALL word
    ld   dos_r64, [x]
    ld   LINK_HI, x
    ld   dos_r64 >> 8, [x]
    ld   word >> 8, y
    jmp  word
dos_r64:
    beq  cdl_name
    ld   boot_name >> 8, y
    jmp  boot_name

dir_ptr:
    ld   ac, [d_t]
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    add  DOS_DIR >> 8, ac
    ld   ac, [d_ph]
    ld   [d_t], ac
    shl
    shl
    shl
    shl
    ld   ac, [d_pl]
    ld   [LINK_HI], y
    jmp  [LINK_LO]


#addr 0x8B00
c_load:
    ld   LINK_LO, x             ; CALL word
    ld   dos_r65, [x]
    ld   LINK_HI, x
    ld   dos_r65 >> 8, [x]
    ld   word >> 8, y
    jmp  word
dos_r65:
    beq  cl_name
    ld   LINK_LO, x             ; CALL hex4
    ld   dos_r66, [x]
    ld   LINK_HI, x
    ld   dos_r66 >> 8, [x]
    ld   hex4 >> 8, y
    jmp  hex4
dos_r66:
    bne  cl_hex
    ld   [d_al], ac
    ld   ac, [R4]
    ld   [d_ah], ac
    ld   ac, [R5]
    ld   d_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_load
    ld   dos_r67, [x]
    ld   LINK_HI, x
    ld   dos_r67 >> 8, [x]
    ld   fs_load >> 8, y
    jmp  fs_load
dos_r67:
    bne  cl_err
    ld   s_loaded & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_loaded >> 8, ac
    ld   ac, [d_msgh]
    ld   br_draw >> 8, y
    jmp  br_draw
cl_err:
    ld   fail >> 8, y
    jmp  fail
cl_name:
    ld   need_name >> 8, y
    jmp  need_name
cl_hex:
    ld   need_hex >> 8, y
    jmp  need_hex

c_save:
    ld   LINK_LO, x             ; CALL word
    ld   dos_r68, [x]
    ld   LINK_HI, x
    ld   dos_r68 >> 8, [x]
    ld   word >> 8, y
    jmp  word
dos_r68:
    beq  cs_name
    ld   LINK_LO, x             ; CALL hex4
    ld   dos_r69, [x]
    ld   LINK_HI, x
    ld   dos_r69 >> 8, [x]
    ld   hex4 >> 8, y
    jmp  hex4
dos_r69:
    bne  cs_hex
    ld   [d_al], ac
    ld   ac, [d_ll]
    ld   ac, [d_el]
    ld   [d_ah], ac
    ld   ac, [d_lh]
    ld   ac, [d_eh]
    ld   LINK_LO, x             ; CALL hex4
    ld   dos_r70, [x]
    ld   LINK_HI, x
    ld   dos_r70 >> 8, [x]
    ld   hex4 >> 8, y
    jmp  hex4
dos_r70:
    bne  cs_hex
    ld   [d_al], ac
    ld   ac, [d_cl]
    ld   [d_ah], ac
    ld   ac, [d_ch]
    ld   [d_cl], ac
    or   [d_ch], ac
    beq  cs_hex                 ; a length of 0
    ld   LINK_LO, x             ; CALL hex4
    ld   dos_r71, [x]
    ld   LINK_HI, x
    ld   dos_r71 >> 8, [x]
    ld   hex4 >> 8, y
    jmp  hex4
dos_r71:
    bne  cs_go                  ; no entry given: the start
    ld   [d_al], ac
    ld   ac, [d_el]
    ld   [d_ah], ac
    ld   ac, [d_eh]
cs_go:
    ld   save_plc >> 8, y
    jmp  save_plc
cs_name:
    ld   need_name >> 8, y
    jmp  need_name
cs_hex:
    ld   need_hex >> 8, y
    jmp  need_hex

dl_list:
    ld   [d_i], ac
    xor  [d_n], ac
    beq  dl_done
    ld   [d_row], ac
    xor  LIST_ROW + LIST_N, ac
    beq  dl_done
    ld   LINK_LO, x             ; CALL show_ent
    ld   dos_r86, [x]
    ld   LINK_HI, x
    ld   dos_r86 >> 8, [x]
    ld   show_ent >> 8, y
    jmp  show_ent
dos_r86:
    ld   [d_i], ac
    inc
    ld   ac, [d_i]
    ld   [d_row], ac
    inc
    ld   ac, [d_row]
    bra  dl_list
dl_done:
    ld   [d_n], ac
    beq  dl_x
    ld   TINT_BAR, ac
    ld   LINK_LO, x             ; CALL bar_set
    ld   dos_r87, [x]
    ld   LINK_HI, x
    ld   dos_r87 >> 8, [x]
    ld   bar_set >> 8, y
    jmp  bar_set
dos_r87:
dl_x:
    ld   lib_leave >> 8, y
    jmp  lib_leave


#addr 0x8C00
        ; d_eh:d_el entry: the header, then create / write / close
save_plc:
    ld   DOS_BUF >> 8, y
    ld   0, x
    ld   0x50, [y,x]            ; "PLC"
    ld   1, x
    ld   0x4C, [y,x]
    ld   2, x
    ld   0x43, [y,x]
    ld   [d_lh], ac             ; type: 1 when the start is 0000
    or   [d_ll], ac
    bne  sp_t0
    ld   1, ac
    bra  sp_ty
sp_t0:
    clr  ac
sp_ty:
    ld   3, x
    ld   ac, [y,x]
    ld   4, x
    ld   [d_ll], ac
    ld   ac, [y,x]
    ld   5, x
    ld   [d_lh], ac
    ld   ac, [y,x]
    ld   6, x
    ld   [d_cl], ac
    ld   ac, [y,x]
    ld   7, x
    ld   [d_ch], ac
    ld   ac, [y,x]
    ld   8, x
    ld   [d_el], ac
    ld   ac, [y,x]
    ld   9, x
    ld   [d_eh], ac
    ld   ac, [y,x]
    ld   10, x                  ; bytes 10-15 = 0
    ld   0, [y,x]
    ld   11, x
    ld   0, [y,x]
    ld   12, x
    ld   0, [y,x]
    ld   13, x
    ld   0, [y,x]
    ld   14, x
    ld   0, [y,x]
    ld   15, x
    ld   0, [y,x]
sp_cp:
    ld   [d_ll], ac             ; the first 496 bytes after the header
    ld   ac, [R0]
    ld   [d_lh], ac
    ld   ac, [R1]
    ld   (DOS_BUF & 0xFF) + 16, ac
    ld   ac, [R2]
    ld   DOS_BUF >> 8, ac
    ld   ac, [R3]
    clr  ac
    ld   ac, [R4]
    ld   LINK_LO, x             ; CALL memcpy
    ld   dos_r72, [x]
    ld   LINK_HI, x
    ld   dos_r72 >> 8, [x]
    ld   memcpy >> 8, y
    jmp  memcpy
dos_r72:
    ld   240, ac
    ld   ac, [R4]
    ld   LINK_LO, x             ; CALL memcpy
    ld   dos_r73, [x]
    ld   LINK_HI, x
    ld   dos_r73 >> 8, [x]
    ld   memcpy >> 8, y
    jmp  memcpy
dos_r73:
    ld   [R0], ac               ; the next source byte
    ld   ac, [d_ll]
    ld   [R1], ac
    ld   ac, [d_lh]
    ld   sp_write >> 8, y
    jmp  sp_write

        ; left out), d_n = how many.  AC = 0, or the error (also shown)
dir_read:
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
    clr  ac
    ld   ac, [d_n]
    ld   FSV, y
    ld   V_TYPE, x
    ld   [y,x], ac
    bne  dr_ok
    ld   LINK_LO, x             ; no card yet
    ld   dos_r78, [x]
    ld   LINK_HI, x
    ld   dos_r78 >> 8, [x]
    ld   mount >> 8, y
    jmp  mount
dos_r78:
    bne  dr_nocard
dr_ok:
    ld   LINK_LO, x             ; CALL fs_cwd
    ld   dos_r79, [x]
    ld   LINK_HI, x
    ld   dos_r79 >> 8, [x]
    ld   fs_cwd >> 8, y
    jmp  fs_cwd
dos_r79:
    bne  dr_fail
    ld   dr_next >> 8, y
    jmp  dr_next
dr_nocard:
    ld   ac, [d_err]
    ld   s_nocard & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_nocard >> 8, ac
    ld   ac, [d_msgh]
    ld   lib_leave >> 8, y
    jmp  lib_leave
dr_fail:
    ld   ac, [d_err]
    ld   s_err & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_err >> 8, ac
    ld   ac, [d_msgh]
    ld   lib_leave >> 8, y
    jmp  lib_leave


#addr 0x8D00
sp_write:
    ld   [d_cl], ac             ; the file's size = length + 16
    add  16, ac
    ld   ac, [d_cl]
    ld   ac, [d_al]
    ld   [d_ch], ac
    bcc  sp_w1
    inc
    ld   ac, [d_ch]
sp_w1:
    ld   ac, [d_ah]
    ld   d_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL fs_create
    ld   dos_r74, [x]
    ld   LINK_HI, x
    ld   dos_r74 >> 8, [x]
    ld   fs_create >> 8, y
    jmp  fs_create
dos_r74:
    bne  sp_err
    ld   DOS_BUF & 0xFF, ac     ; the first sector
    ld   ac, [R4]
    ld   DOS_BUF >> 8, ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_write
    ld   dos_r75, [x]
    ld   LINK_HI, x
    ld   dos_r75 >> 8, [x]
    ld   fs_write >> 8, y
    jmp  fs_write
dos_r75:
    bne  sp_err
sp_more:
    ld   [d_ch], ac             ; 512 bytes written: more?
    sub  2, ac
    bcs  sp_close
    ld   ac, [d_ch]
    or   [d_cl], ac
    beq  sp_close
    ld   [d_ll], ac
    ld   ac, [R4]
    ld   [d_lh], ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL fs_write
    ld   dos_r76, [x]
    ld   LINK_HI, x
    ld   dos_r76 >> 8, [x]
    ld   fs_write >> 8, y
    jmp  fs_write
dos_r76:
    bne  sp_err
    ld   [R4], ac
    ld   ac, [d_ll]
    ld   [R5], ac
    ld   ac, [d_lh]
    bra  sp_more
sp_close:
    ld   [d_al], ac
    ld   ac, [R0]
    ld   [d_ah], ac
    ld   ac, [R1]
    clr  ac
    ld   ac, [R2]
    ld   ac, [R3]
    ld   LINK_LO, x             ; CALL fs_close
    ld   dos_r77, [x]
    ld   LINK_HI, x
    ld   dos_r77 >> 8, [x]
    ld   fs_close >> 8, y
    jmp  fs_close
dos_r77:
    bne  sp_err
    ld   s_saved & 0xFF, ac
    ld   ac, [d_msgl]
    ld   s_saved >> 8, ac
    ld   ac, [d_msgh]
    ld   browser >> 8, y
    jmp  browser
sp_err:
    ld   fail >> 8, y
    jmp  fail

; ============================================================
; the folder: dir_read, dir_ptr, ent_name
; ============================================================
; a leaf)
bar_set:
    ld   ac, [d_t2]
    ld   [d_sel], ac
    sub  [d_top], ac
    add  LIST_ROW + 4, ac       ; MODE_BASE + 8 * row = x5A00 + 8 * (row + 4)
    ld   ac, [d_t]
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    add  MODE_BASE >> 8, ac
    ld   ac, [d_mh]
    ld   [d_t], ac
    shl
    shl
    shl
    ld   ac, [d_ml]
    ld   7, ac
    ld   ac, [d_t]
bs_l:
    ld   [d_mh], y
    ld   [d_ml], ac
    add  [d_t], x
    ld   [d_t2], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    sub  1, ac
    ld   ac, [d_t]
    bcc  bs_l
    ld   [LINK_HI], y
    jmp  [LINK_LO]

streq:
    clr  ac
    ld   ac, [d_t]
sq_l:
    ld   [R1], y
    ld   [R0], ac
    add  [d_t], x
    ld   [y,x], ac
    ld   ac, [d_c]
    ld   [d_t], ac
    add  d_name, x
    ld   [x], ac
    xor  [d_c], ac
    bne  sq_ne
    ld   [d_c], ac
    beq  sq_eq
    ld   [d_t], ac
    inc
    ld   ac, [d_t]
    bra  sq_l
sq_ne:
    ld   1, ac
sq_eq:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; strings
; ============================================================

#addr 0x8E00
dr_next:
    ld   LINK_LO, x             ; CALL fs_next
    ld   dos_r80, [x]
    ld   LINK_HI, x
    ld   dos_r80 >> 8, [x]
    ld   fs_next >> 8, y
    jmp  fs_next
dos_r80:
    bne  dr_end
    ld   FSV, y                 ; "." and "..": left out
    ld   V_ENTRY, x
    ld   [y,x], ac
    xor  0x2E, ac
    beq  dr_next
    ld   [d_n], ac
    ld   LINK_LO, x             ; CALL dir_ptr
    ld   dos_r81, [x]
    ld   LINK_HI, x
    ld   dos_r81 >> 8, [x]
    ld   dir_ptr >> 8, y
    jmp  dir_ptr
dos_r81:
    ld   11, ac                 ; name and attributes
    ld   ac, [d_t]
drd_cp:
    ld   [d_t], ac
    add  V_ENTRY, x
    ld   FSV, y
    ld   [y,x], ac
    ld   ac, [d_c]
    ld   [d_pl], ac
    add  [d_t], x
    ld   [d_ph], y
    ld   [d_c], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    sub  1, ac
    ld   ac, [d_t]
    bcc  drd_cp
    ld   3, ac                  ; the size
    ld   ac, [d_t]
dr_sz:
    ld   [d_t], ac
    add  V_ENTRY + 28, x
    ld   FSV, y
    ld   [y,x], ac
    ld   ac, [d_c]
    ld   [d_pl], ac
    add  12, ac
    add  [d_t], x
    ld   [d_ph], y
    ld   [d_c], ac
    ld   ac, [y,x]
    ld   [d_t], ac
    sub  1, ac
    ld   ac, [d_t]
    bcc  dr_sz
    ld   [d_n], ac
    inc
    ld   ac, [d_n]
    xor  DIR_MAX, ac
    bne  dr_next
    ld   1, ac                  ; full: as the end
dr_end:
    xor  1, ac                  ; 1 is the end
    beq  dr_done
    xor  1, ac
    ld   dr_fail >> 8, y
    jmp  dr_fail
dr_done:
    ld   lib_leave >> 8, y
    jmp  lib_leave

ent_name:
    clr  ac
    ld   ac, [d_t]              ; the entry's character
    ld   ac, [d_t2]             ; the name's
en_b:
    ld   [d_ph], y
    ld   [d_pl], ac
    add  [d_t], x
    ld   [y,x], ac
    xor  0x20, ac
    beq  en_ext
    xor  0x20, ac
    ld   ac, [d_c]
    ld   [d_t2], ac
    add  d_name, x
    ld   [d_c], ac
    ld   ac, [x]
    ld   [d_t2], ac
    inc
    ld   ac, [d_t2]
    ld   [d_t], ac
    inc
    ld   ac, [d_t]
    xor  8, ac
    bne  en_b
en_ext:
    ld   8, ac
    ld   ac, [d_t]
    ld   [d_ph], y
    ld   [d_pl], ac
    add  8, x
    ld   [y,x], ac
    xor  0x20, ac
    beq  en_end
    ld   [d_t2], ac
    add  d_name, x
    ld   0x2E, [x]
    ld   [d_t2], ac
    inc
    ld   ac, [d_t2]
en_e:
    ld   [d_ph], y
    ld   [d_pl], ac
    add  [d_t], x
    ld   [y,x], ac
    xor  0x20, ac
    beq  en_end
    xor  0x20, ac
    ld   ac, [d_c]
    ld   [d_t2], ac
    add  d_name, x
    ld   [d_c], ac
    ld   ac, [x]
    ld   [d_t2], ac
    inc
    ld   ac, [d_t2]
    ld   [d_t], ac
    inc
    ld   ac, [d_t]
    xor  11, ac
    bne  en_e
en_end:
    ld   [d_t2], ac
    add  d_name, x
    ld   0, [x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; the screen: draw_list, show_ent, bar_set, show_msg, clr_row
; ============================================================

#addr 0x8F00
draw_list:
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
    ld   LINK_LO, x             ; CALL con_clear
    ld   dos_r82, [x]
    ld   LINK_HI, x
    ld   dos_r82 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
dos_r82:
    ld   s_title & 0xFF, ac
    ld   ac, [R0]
    ld   s_title >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r83, [x]
    ld   LINK_HI, x
    ld   dos_r83 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r83:
    ld   MB_FNAME, ac
    ld   ac, [R0]
    ld   MENU_BLK >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r84, [x]
    ld   LINK_HI, x
    ld   dos_r84 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r84:
    ld   HELP_ROW, ac
    ld   ac, [CUR_ROW]
    clr  ac
    ld   ac, [CUR_COL]
    ld   s_help & 0xFF, ac
    ld   ac, [R0]
    ld   s_help >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r85, [x]
    ld   LINK_HI, x
    ld   dos_r85 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r85:
    ld   [d_top], ac
    ld   ac, [d_i]
    ld   LIST_ROW, ac
    ld   ac, [d_row]
    ld   dl_list >> 8, y
    jmp  dl_list

        ; MSG_ROW, then none
show_msg:
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
    ld   [d_msgh], ac
    beq  sm_x
    ld   MSG_ROW, ac
    ld   LINK_LO, x             ; CALL clr_row
    ld   dos_r94, [x]
    ld   LINK_HI, x
    ld   dos_r94 >> 8, [x]
    ld   clr_row >> 8, y
    jmp  clr_row
dos_r94:
    ld   [d_msgl], ac
    ld   ac, [R0]
    ld   [d_msgh], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r95, [x]
    ld   LINK_HI, x
    ld   dos_r95 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r95:
    ld   [d_err], ac
    beq  sm_c
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   dos_r96, [x]
    ld   LINK_HI, x
    ld   dos_r96 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
dos_r96:
    ld   [d_err], ac
    ld   LINK_LO, x             ; CALL con_dec8
    ld   dos_r97, [x]
    ld   LINK_HI, x
    ld   dos_r97 >> 8, [x]
    ld   con_dec8 >> 8, y
    jmp  con_dec8
dos_r97:
sm_c:
    clr  ac
    ld   ac, [d_msgh]
    ld   ac, [d_err]
sm_x:
    ld   lib_leave >> 8, y
    jmp  lib_leave

s_notdir:   #d "Not a folder", 0x00
s_deleted:  #d "Deleted", 0x00
s_prompt:   #d "> ", 0x00
s_cfg:      #d "BOOT.CFG", 0x00


#addr 0x9000
show_ent:
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
    ld   [d_row], ac
    ld   ac, [CUR_ROW]
    ld   2, ac
    ld   ac, [CUR_COL]
    ld   [d_i], ac
    ld   LINK_LO, x             ; CALL dir_ptr
    ld   dos_r88, [x]
    ld   LINK_HI, x
    ld   dos_r88 >> 8, [x]
    ld   dir_ptr >> 8, y
    jmp  dir_ptr
dos_r88:
    ld   LINK_LO, x             ; CALL ent_name
    ld   dos_r89, [x]
    ld   LINK_HI, x
    ld   dos_r89 >> 8, [x]
    ld   ent_name >> 8, y
    jmp  ent_name
dos_r89:
    ld   d_name, ac
    ld   ac, [R0]
    clr  ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r90, [x]
    ld   LINK_HI, x
    ld   dos_r90 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r90:
    ld   16, ac
    ld   ac, [CUR_COL]
    ld   [d_ph], y
    ld   [d_pl], ac
    add  11, x
    ld   [y,x], ac
    and  0x10, ac
    bne  se_dir
    ld   [d_pl], ac
    add  14, x
    ld   [y,x], ac
    ld   ac, [d_t]
    ld   [d_pl], ac
    add  15, x
    ld   [y,x], ac
    or   [d_t], ac
    bne  se_big
    ld   [d_pl], ac
    add  12, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   [d_pl], ac
    add  13, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_dec16
    ld   dos_r91, [x]
    ld   LINK_HI, x
    ld   dos_r91 >> 8, [x]
    ld   con_dec16 >> 8, y
    jmp  con_dec16
dos_r91:
    ld   lib_leave >> 8, y
    jmp  lib_leave
se_dir:
    ld   s_dir & 0xFF, ac
    ld   ac, [R0]
    ld   s_dir >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r92, [x]
    ld   LINK_HI, x
    ld   dos_r92 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r92:
    ld   lib_leave >> 8, y
    jmp  lib_leave
se_big:
    ld   s_big & 0xFF, ac
    ld   ac, [R0]
    ld   s_big >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x             ; CALL con_puts
    ld   dos_r93, [x]
    ld   LINK_HI, x
    ld   dos_r93 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
dos_r93:
    ld   lib_leave >> 8, y
    jmp  lib_leave

clr_row:
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
    ld   ac, [CUR_ROW]
    clr  ac
    ld   ac, [CUR_COL]
    ld   79, ac
    ld   ac, [d_t]
cr_l:
    ld   0x20, ac
    ld   LINK_LO, x             ; CALL con_putc
    ld   dos_r98, [x]
    ld   LINK_HI, x
    ld   dos_r98 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
dos_r98:
    ld   [d_t], ac
    dec
    ld   ac, [d_t]
    bne  cr_l
    clr  ac
    ld   ac, [CUR_COL]
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ============================================================
; the command line's words: word, hex4, streq
; ============================================================

#addr 0x9100
        ; case (12 characters at most); AC = its length (a leaf)
word:
    clr  ac
    ld   ac, [d_len]
w_sk:
    ld   DOS_LINE >> 8, y
    ld   [d_pos], x
    ld   [y,x], ac
    xor  0x20, ac
    bne  w_cp
    ld   [d_pos], ac
    inc
    ld   ac, [d_pos]
    bra  w_sk
w_cp:
    ld   [d_pos], x
    ld   [y,x], ac
    beq  w_end
    xor  0x20, ac
    beq  w_end
    xor  0x20, ac
    ld   ac, [d_c]
    sub  0x61, ac               ; a-z to A-Z
    blt  w_st
    ld   [d_c], ac
    sub  0x7B, ac
    bcc  w_st
    ld   [d_c], ac
    sub  0x20, ac
    ld   ac, [d_c]
w_st:
    ld   [d_len], ac
    xor  12, ac
    beq  w_skip
    ld   [d_len], ac
    add  d_name, x
    ld   [d_c], ac
    ld   ac, [x]
    ld   [d_len], ac
    inc
    ld   ac, [d_len]
w_skip:
    ld   [d_pos], ac
    inc
    ld   ac, [d_pos]
    ld   DOS_LINE >> 8, y
    bra  w_cp
w_end:
    ld   [d_len], ac
    add  d_name, x
    ld   0, [x]
    ld   [d_len], ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]

        ; AC = 0, or 1 with no digits (a leaf)
hex4:
    clr  ac
    ld   ac, [d_al]
    ld   ac, [d_ah]
    ld   ac, [d_len]
h_sk:
    ld   DOS_LINE >> 8, y
    ld   [d_pos], x
    ld   [y,x], ac
    xor  0x20, ac
    bne  h_d
    ld   [d_pos], ac
    inc
    ld   ac, [d_pos]
    bra  h_sk
h_d:
    ld   [d_pos], x
    ld   [y,x], ac
    ld   ac, [d_c]
    sub  0x61, ac               ; a-f to A-F
    blt  h_d1
    ld   [d_c], ac
    sub  0x20, ac
    ld   ac, [d_c]
h_d1:
    ld   [d_c], ac
    sub  0x30, ac
    blt  h_end
    ld   ac, [d_c]              ; 0-9?
    sub  10, ac
    blt  h_dig
    ld   [d_c], ac
    sub  17, ac                 ; A-F?
    blt  h_end
    add  10, ac
    ld   ac, [d_c]
    sub  16, ac
    blt  h_dig
    bra  h_end
h_dig:
    ld   [d_ah], ac
    shl
    shl
    shl
    shl
    ld   ac, [d_ah]
    ld   [d_al], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    or   [d_ah], ac
    ld   ac, [d_ah]
    ld   [d_al], ac
    shl
    shl
    shl
    shl
    or   [d_c], ac
    ld   ac, [d_al]
    ld   [d_len], ac
    inc
    ld   ac, [d_len]
    ld   [d_pos], ac
    inc
    ld   ac, [d_pos]
    ld   DOS_LINE >> 8, y
    bra  h_d
h_end:
    ld   [d_len], ac
    beq  h_bad
    clr  ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]
h_bad:
    ld   1, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]


#addr 0x9200
s_title:    #d "PLACARD DOS    folder ", 0x00
s_hold:     #d "Hold Esc for the file browser", 0x00
s_help:     #d "Up/Down move  Enter run/open  Bksp up  Del delete  B boot  R reread  Esc command", 0x00
s_dir:      #d "<DIR>", 0x00
s_big:      #d ">64K", 0x00
s_err:      #d "Error", 0x00
s_nocard:   #d "No SD card: insert one and press R", 0x00
s_notprog:  #d "Not a program (.PLC)", 0x00
s_isdir:    #d "That is a folder", 0x00


#addr 0x9300
s_boots:    #d "BOOT.CFG written: that program runs at power-up (hold Esc for the browser)", 0x00
s_rootonly: #d "BOOT.CFG is read from the root folder: go there first", 0x00
s_unknown:  #d "Commands: RUN LOAD SAVE DEL CD BOOT DIR", 0x00
s_name:     #d "Which file?", 0x00
s_syntax:   #d "LOAD name hhhh   SAVE name hhhh(start) hhhh(length) [hhhh(entry)]", 0x00


#addr 0x9400
s_loaded:   #d "Loaded", 0x00
s_saved:    #d "Saved", 0x00
s_run:      #d "RUN", 0x00
s_load:     #d "LOAD", 0x00
s_save:     #d "SAVE", 0x00
s_del:      #d "DEL", 0x00
s_cd:       #d "CD", 0x00
s_boot:     #d "BOOT", 0x00
s_dirc:     #d "DIR", 0x00

#addr 0xFC00
    #d8 MODE_DOS


; ============================================================
; dos_start - the boot loader comes here with map 05
; ============================================================
