; ============================================================
; placard_fs.asm - Placard FAT file reading from the SD card
; ============================================================
;
; Reads files from an SD card formatted FAT16 or FAT32 (as cards and PCs
; format them), with or without a partition table:
;
;     fs_mount     find the file system (sd_init first); the root
;                  folder is the current folder
;     fs_root      go back to the root folder
;     fs_next      the next entry of the current folder (a listing)
;     fs_open      find a name in the current folder: a file opens for
;                  fs_read, a folder becomes the current folder
;     fs_read      the next 512 bytes of the open file
;     fs_load      fs_open + fs_read to the end: load a file
;
; Read only: nothing here writes the card.  Names are short (8.3) names,
; as DOS shows them; a long name is found by its short form (for example
; "LONGFI~1.TXT").  FAT12 (volumes under about 16 MB) is not read.
;
; There is one reader: after fs_open of a file, fs_next starts the
; folder's listing over, and fs_read can't go on after fs_next or another
; fs_open.
;
; Errors (AC): 1 end (of the file or folder), 2 not found, 4 and 5 from
; sd_read, 8 not mounted, 9 no FAT file system, 10 FAT12.
;
; The routines keep their state at FS_VARS (x4D00-x4D7F) and use FS_BUF
; (x4E00-x4FFF) for folder and FAT sectors, both in section 2, which must
; read RAM (it does in the standard map 05).  They change R0-R5 and the
; I/O drivers' zero page bytes, besides T0-T7.  placard_lib.asm includes
; this file, in library bank 2.
;
; Date: 10/18/2026
; ============================================================

FS_VARS   = 0x4D00      ; the file system's variables, 128 bytes
FS_BUF    = 0x4E00      ; 512-byte buffer for folder and FAT sectors
FSV       = 0x4D        ; their pages
FSB       = 0x4E

; offsets in FS_VARS
V_PART    = 0x00        ; 4: first sector of the volume
V_FAT     = 0x04        ; 4: first sector of the FAT
V_DATA    = 0x08        ; 4: first sector of cluster 2
V_ROOT    = 0x0C        ; 4: FAT16 root folder sector, FAT32 root cluster
V_SPC     = 0x10        ; sectors per cluster
V_SHIFT   = 0x11        ; log2 of it
V_TYPE    = 0x12        ; 16 or 32 when mounted, else 0
V_RSECS   = 0x13        ; FAT16: sectors in the root folder
V_TMPT    = 0x14        ; type while mounting
V_OFF     = 0x15        ; FAT entry: offset in its sector
V_OFFP    = 0x16        ; and its page in FS_BUF
V_ONDIR   = 0x17        ; 1: the reader is on the current folder
V_SLBA    = 0x18        ; 4: next sector to read
V_SCLUS   = 0x1C        ; 4: cluster being read
V_SSEC    = 0x20        ; sectors left in the cluster (or root folder)
V_SMODE   = 0x21        ; 1: no more clusters (the FAT16 root, or the end)
V_DIRI    = 0x22        ; next entry in FS_BUF, 16 = read the next sector
V_UBUF    = 0x23        ; 2: buffer address for fs_snext
V_LBUF    = 0x25        ; 2: load address for fs_load
V_REM     = 0x28        ; 4: bytes of the open file not read yet
V_FATC    = 0x2C        ; 4: the FAT sector in FS_BUF (xFF...: none)
V_NAME    = 0x30        ; 11: name being looked for, "NAME    EXT"
V_ENTRY   = 0x40        ; 32: the last folder entry fs_next found
V_DCLUS   = 0x60        ; 4: the current folder's first cluster, 0 = root

FS_ENTRY  = FS_VARS + V_ENTRY   ; the entry: name 0-10, attributes 11
                                ; (10h folder), size 28-31 (low first)
FS_REM    = FS_VARS + V_REM     ; bytes of the open file left to read


; ============================================================
; Page 6: 32-bit helpers on T0-T3 (and T4-T7)
; ============================================================
#addr LIB2_CODE + 0x600

; fs_get - T0-T3 = 4 bytes of FS_VARS at offset AC.  Changes X, Y.
fs_get:
    ld   ac, x
    ld   FSV, y
    ld   [y,x], ac
    ld   ac, [T0]
    ld   x, ac
    inc
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [T1]
    ld   x, ac
    inc
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [T2]
    ld   x, ac
    inc
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [T3]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; fs_getb - T4-T7 = 4 bytes of FS_VARS at offset AC.  Changes X, Y.
fs_getb:
    ld   ac, x
    ld   FSV, y
    bra  gb_go

; fs_bget - T4-T7 = 4 bytes of FS_BUF at offset AC (fs_bget1: FS_BUF +
; x100 + AC).  Changes X, Y.
fs_bget1:
    ld   ac, x
    ld   FSB + 1, y
    bra  gb_go
fs_bget:
    ld   ac, x
    ld   FSB, y
gb_go:
    ld   [y,x], ac
    ld   ac, [T4]
    ld   x, ac
    inc
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [T5]
    ld   x, ac
    inc
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [T6]
    ld   x, ac
    inc
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [T7]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; fs_put - 4 bytes of FS_VARS at offset AC = T0-T3.  Changes X, Y.
fs_put:
    ld   ac, x
    ld   FSV, y
    ld   [T0], ac
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    ld   [T1], ac
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    ld   [T2], ac
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    ld   [T3], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; fs_shl - T0-T3 = T0-T3 << 1
fs_shl:
    ld   [T3], ac
    shl
    ld   ac, [T3]
    ld   [T2], ac
    bge  sh_2
    ld   [T3], ac
    or   1, ac
    ld   ac, [T3]
sh_2:
    ld   [T2], ac
    shl
    ld   ac, [T2]
    ld   [T1], ac
    bge  sh_1
    ld   [T2], ac
    or   1, ac
    ld   ac, [T2]
sh_1:
    ld   [T1], ac
    shl
    ld   ac, [T1]
    ld   [T0], ac
    bge  sh_0
    ld   [T1], ac
    or   1, ac
    ld   ac, [T1]
sh_0:
    ld   [T0], ac
    shl
    ld   ac, [T0]
    ld   [LINK_HI], y
    jmp  [LINK_LO]


; ============================================================
; Page 7: 32-bit add, cluster to sector
; ============================================================
#addr LIB2_CODE + 0x700

; fs_add - T0-T3 = T0-T3 + T4-T7.  Changes IO_T0-IO_T3.
fs_add:
    clr  ac
    ld   ac, [IO_T3]            ; carry in
    ld   [T0], ac
    add  [T4], ac
    ld   ac, [IO_T0]            ; sum
    ld   [T0], ac
    and  [T4], ac
    ld   ac, [IO_T1]            ; a & b
    ld   [T0], ac
    or   [T4], ac
    ld   ac, [IO_T2]            ; a | b
    ld   [IO_T0], ac
    ld   ac, [T0]
    not
    and  [IO_T2], ac
    or   [IO_T1], ac            ; bit 7 = carry out
    blt  ad_c0
    clr  ac
    bra  ad_d0
ad_c0:
    ld   1, ac
ad_d0:
    ld   ac, [IO_T3]
    ld   [T1], ac
    add  [T5], ac
    add  [IO_T3], ac
    ld   ac, [IO_T0]
    ld   [T1], ac
    and  [T5], ac
    ld   ac, [IO_T1]
    ld   [T1], ac
    or   [T5], ac
    ld   ac, [IO_T2]
    ld   [IO_T0], ac
    ld   ac, [T1]
    not
    and  [IO_T2], ac
    or   [IO_T1], ac
    blt  ad_c1
    clr  ac
    bra  ad_d1
ad_c1:
    ld   1, ac
ad_d1:
    ld   ac, [IO_T3]
    ld   [T2], ac
    add  [T6], ac
    add  [IO_T3], ac
    ld   ac, [IO_T0]
    ld   [T2], ac
    and  [T6], ac
    ld   ac, [IO_T1]
    ld   [T2], ac
    or   [T6], ac
    ld   ac, [IO_T2]
    ld   [IO_T0], ac
    ld   ac, [T2]
    not
    and  [IO_T2], ac
    or   [IO_T1], ac
    blt  ad_c2
    clr  ac
    bra  ad_d2
ad_c2:
    ld   1, ac
ad_d2:
    ld   ac, [IO_T3]
    ld   [T3], ac
    add  [T7], ac
    add  [IO_T3], ac
    ld   ac, [T3]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; fs_clba - T0-T3 = the first sector of cluster T0-T3:
; V_DATA + (cluster - 2) << V_SHIFT.  Changes T4-T7, IO_T0-IO_T3, IO_TMP.
fs_clba:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [SAVE_AC], ac
    ld   0xFE, ac
    ld   ac, [T4]
    ld   0xFF, ac
    ld   ac, [T5]
    ld   ac, [T6]
    ld   ac, [T7]
    ld   LINK_LO, x
    ld   fs_r1, [x]
    ld   LINK_HI, x
    ld   fs_r1 >> 8, [x]
    ld   fs_add >> 8, y
    jmp  fs_add
fs_r1:
    ld   FSV, y
    ld   V_SHIFT, x
    ld   [y,x], ac
cl_loop:
    beq  cl_add
    ld   ac, [IO_TMP]
    ld   LINK_LO, x
    ld   fs_r2, [x]
    ld   LINK_HI, x
    ld   fs_r2 >> 8, [x]
    ld   fs_shl >> 8, y
    jmp  fs_shl
fs_r2:
    ld   [IO_TMP], ac
    dec
    bra  cl_loop
cl_add:
    ld   V_DATA, ac
    ld   LINK_LO, x
    ld   fs_r3, [x]
    ld   LINK_HI, x
    ld   fs_r3 >> 8, [x]
    ld   fs_getb >> 8, y
    jmp  fs_getb
fs_r3:
    ld   LINK_LO, x
    ld   fs_r4, [x]
    ld   LINK_HI, x
    ld   fs_r4 >> 8, [x]
    ld   fs_add >> 8, y
    jmp  fs_add
fs_r4:
    ld   lib_leave >> 8, y
    jmp  lib_leave


; ============================================================
; Pages 8-10: following the FAT, fs_chain
; ============================================================
#addr LIB2_CODE + 0x800

; fs_nextc - V_SCLUS = the next cluster from the FAT
;   out: AC = 0, or 1 at the end of the chain, or an sd_read error
fs_nextc:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [SAVE_AC], ac
    ld   V_SCLUS, ac
    ld   LINK_LO, x
    ld   fs_r5, [x]
    ld   LINK_HI, x
    ld   fs_r5 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fs_r5:
    ld   FSV, y
    ld   V_TYPE, x
    ld   [y,x], ac
    xor  32, ac
    beq  nc_32
    ld   [T0], ac               ; FAT16: entry at byte cluster * 2
    shl
    ld   V_OFF, x
    ld   ac, [y,x]
    ld   [T1], ac               ; sector = cluster >> 8
    ld   ac, [T4]
    ld   [T0], ac
    bge  nc_p0
    ld   FSB + 1, ac
    bra  nc_p
nc_p0:
    ld   FSB, ac
nc_p:
    ld   V_OFFP, x
    ld   ac, [y,x]
    ld   [T4], ac
    ld   ac, [T0]
    clr  ac
    ld   ac, [T1]
    ld   ac, [T2]
    ld   ac, [T3]
    bra  nc_s
nc_32:
    ld   LINK_LO, x
    ld   fs_r6, [x]
    ld   LINK_HI, x
    ld   fs_r6 >> 8, [x]
    ld   fs_shl >> 8, y
    jmp  fs_shl
fs_r6:
    ld   FSV, y
    ld   [T0], ac
    shl
    ld   V_OFF, x
    ld   ac, [y,x]
    ld   [T0], ac
    bge  nc_q0
    ld   FSB + 1, ac
    bra  nc_q
nc_q0:
    ld   FSB, ac
nc_q:
    ld   V_OFFP, x
    ld   ac, [y,x]
    ld   [T1], ac               ; sector = (cluster << 1) >> 8
    ld   ac, [T0]
    ld   [T2], ac
    ld   ac, [T1]
    ld   [T3], ac
    ld   ac, [T2]
    clr  ac
    ld   ac, [T3]
nc_s:
    ld   nc_sec >> 8, y
    jmp  nc_sec

#addr LIB2_CODE + 0x900
nc_sec:
    ld   V_FAT, ac
    ld   LINK_LO, x
    ld   fs_r7, [x]
    ld   LINK_HI, x
    ld   fs_r7 >> 8, [x]
    ld   fs_getb >> 8, y
    jmp  fs_getb
fs_r7:
    ld   LINK_LO, x
    ld   fs_r8, [x]
    ld   LINK_HI, x
    ld   fs_r8 >> 8, [x]
    ld   fs_add >> 8, y
    jmp  fs_add
fs_r8:
    ld   V_FATC, ac
    ld   LINK_LO, x
    ld   fs_r9, [x]
    ld   LINK_HI, x
    ld   fs_r9 >> 8, [x]
    ld   fs_getb >> 8, y
    jmp  fs_getb
fs_r9:
    ld   [T0], ac
    xor  [T4], ac
    bne  nc_rd
    ld   [T1], ac
    xor  [T5], ac
    bne  nc_rd
    ld   [T2], ac
    xor  [T6], ac
    bne  nc_rd
    ld   [T3], ac
    xor  [T7], ac
    beq  nc_hv
nc_rd:
    ld   V_FATC, ac
    ld   LINK_LO, x
    ld   fs_r10, [x]
    ld   LINK_HI, x
    ld   fs_r10 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r10:
    ld   [T0], ac
    ld   ac, [R0]
    ld   [T1], ac
    ld   ac, [R1]
    ld   [T2], ac
    ld   ac, [R2]
    ld   [T3], ac
    ld   ac, [R3]
    clr  ac
    ld   ac, [R4]
    ld   FSB, ac
    ld   ac, [R5]
    ld   LINK_LO, x
    ld   fs_r11, [x]
    ld   LINK_HI, x
    ld   fs_r11 >> 8, [x]
    ld   sd_read >> 8, y
    jmp  sd_read
fs_r11:
    beq  nc_hv
    ld   ac, [IO_TMP]
    ld   FSV, y                 ; no FAT sector in the buffer now
    ld   V_FATC + 3, x
    ld   0xFF, [y,x]
    ld   [IO_TMP], ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
nc_hv:
    ld   nc_have >> 8, y
    jmp  nc_have

#addr LIB2_CODE + 0xA00
nc_have:                        ; the FAT sector is in FS_BUF
    ld   FSV, y
    ld   V_OFFP, x
    ld   [y,x], ac
    ld   ac, [IO_T1]
    ld   V_OFF, x
    ld   [y,x], ac
    ld   ac, x
    ld   [IO_T1], y
    ld   [y,x], ac
    ld   ac, [T0]
    ld   x, ac
    inc
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [T1]
    ld   x, ac
    inc
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [T2]
    ld   x, ac
    inc
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [T3]
    ld   FSV, y
    ld   V_TYPE, x
    ld   [y,x], ac
    xor  32, ac
    beq  nc_m32
    clr  ac                     ; FAT16: FFF8-FFFF ends the chain
    ld   ac, [T2]
    ld   ac, [T3]
    ld   [T1], ac
    xor  0xFF, ac
    bne  nc_low
    bra  nc_endq
nc_m32:
    ld   [T3], ac               ; FAT32: 0FFFFFF8-0FFFFFFF
    and  0x0F, ac
    ld   ac, [T3]
    xor  0x0F, ac
    bne  nc_low
    ld   [T2], ac
    and  [T1], ac
    xor  0xFF, ac
    bne  nc_low
nc_endq:
    ld   [T0], ac
    and  0xF8, ac
    xor  0xF8, ac
    beq  nc_end
nc_low:
    ld   [T3], ac               ; 0 and 1 (free, reserved) end it too
    or   [T2], ac
    or   [T1], ac
    bne  nc_ok
    ld   [T0], ac
    and  0xFE, ac
    beq  nc_end
nc_ok:
    ld   V_SCLUS, ac
    ld   LINK_LO, x
    ld   fs_r12, [x]
    ld   LINK_HI, x
    ld   fs_r12 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r12:
    clr  ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
nc_end:
    ld   1, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave


; fs_chain - start the reader at cluster T0-T3 (0: nothing to read)
fs_chain:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [SAVE_AC], ac
    ld   V_SCLUS, ac
    ld   LINK_LO, x
    ld   fs_r13, [x]
    ld   LINK_HI, x
    ld   fs_r13 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r13:
    ld   [T0], ac
    or   [T1], ac
    or   [T2], ac
    or   [T3], ac
    beq  ch_none
    ld   LINK_LO, x
    ld   fs_r14, [x]
    ld   LINK_HI, x
    ld   fs_r14 >> 8, [x]
    ld   fs_clba >> 8, y
    jmp  fs_clba
fs_r14:
    ld   V_SLBA, ac
    ld   LINK_LO, x
    ld   fs_r15, [x]
    ld   LINK_HI, x
    ld   fs_r15 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r15:
    ld   FSV, y
    ld   V_SPC, x
    ld   [y,x], ac
    ld   V_SSEC, x
    ld   ac, [y,x]
    ld   V_SMODE, x
    ld   0, [y,x]
    ld   lib_leave >> 8, y
    jmp  lib_leave
ch_none:
    ld   FSV, y
    ld   V_SSEC, x
    ld   0, [y,x]
    ld   V_SMODE, x
    ld   1, [y,x]
    ld   lib_leave >> 8, y
    jmp  lib_leave


; ============================================================
; Page 11: the reader: next sector, start of a chain, the root
; ============================================================
#addr LIB2_CODE + 0xB00

; fs_snext - read the reader's next sector to R5:R4
;   out: AC = 0 (R5:R4 + 512), 1 at the end, or an sd_read error
fs_snext:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [SAVE_AC], ac
    ld   FSV, y
    ld   V_UBUF, x
    ld   [R4], ac
    ld   ac, [y,x]
    ld   V_UBUF + 1, x
    ld   [R5], ac
    ld   ac, [y,x]
    ld   V_SSEC, x
    ld   [y,x], ac
    bne  sn_have
    ld   V_SMODE, x
    ld   [y,x], ac
    bne  sn_end
    ld   LINK_LO, x
    ld   fs_r16, [x]
    ld   LINK_HI, x
    ld   fs_r16 >> 8, [x]
    ld   fs_nextc >> 8, y
    jmp  fs_nextc
fs_r16:
    bne  sn_ret
    ld   V_SCLUS, ac
    ld   LINK_LO, x
    ld   fs_r17, [x]
    ld   LINK_HI, x
    ld   fs_r17 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fs_r17:
    ld   LINK_LO, x
    ld   fs_r18, [x]
    ld   LINK_HI, x
    ld   fs_r18 >> 8, [x]
    ld   fs_clba >> 8, y
    jmp  fs_clba
fs_r18:
    ld   V_SLBA, ac
    ld   LINK_LO, x
    ld   fs_r19, [x]
    ld   LINK_HI, x
    ld   fs_r19 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r19:
    ld   FSV, y
    ld   V_SPC, x
    ld   [y,x], ac
    ld   V_SSEC, x
    ld   ac, [y,x]
sn_have:
    ld   V_SLBA, ac
    ld   LINK_LO, x
    ld   fs_r20, [x]
    ld   LINK_HI, x
    ld   fs_r20 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fs_r20:
    ld   [T0], ac
    ld   ac, [R0]
    ld   [T1], ac
    ld   ac, [R1]
    ld   [T2], ac
    ld   ac, [R2]
    ld   [T3], ac
    ld   ac, [R3]
    ld   FSV, y
    ld   V_UBUF, x
    ld   [y,x], ac
    ld   ac, [R4]
    ld   V_UBUF + 1, x
    ld   [y,x], ac
    ld   ac, [R5]
    ld   LINK_LO, x
    ld   fs_r21, [x]
    ld   LINK_HI, x
    ld   fs_r21 >> 8, [x]
    ld   sd_read >> 8, y
    jmp  sd_read
fs_r21:
    bne  sn_ret
    ld   V_SLBA, ac
    ld   LINK_LO, x
    ld   fs_r22, [x]
    ld   LINK_HI, x
    ld   fs_r22 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fs_r22:
    ld   1, ac
    ld   ac, [T4]
    clr  ac
    ld   ac, [T5]
    ld   ac, [T6]
    ld   ac, [T7]
    ld   LINK_LO, x
    ld   fs_r23, [x]
    ld   LINK_HI, x
    ld   fs_r23 >> 8, [x]
    ld   fs_add >> 8, y
    jmp  fs_add
fs_r23:
    ld   V_SLBA, ac
    ld   LINK_LO, x
    ld   fs_r24, [x]
    ld   LINK_HI, x
    ld   fs_r24 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r24:
    ld   FSV, y
    ld   V_SSEC, x
    ld   [y,x], ac
    dec
    ld   ac, [y,x]
    clr  ac
sn_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave
sn_end:
    ld   1, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave


; ============================================================
; Page 12: fs_next
; ============================================================
#addr LIB2_CODE + 0xC00

; ------------------------------------------------------------
; fs_next - the next entry of the folder the reader is on
;   in:      -
;   out:     AC = 0 and R1:R0 = FS_ENTRY, a copy of the 32-byte entry
;            (name 0-10, attributes 11: 10h = folder, size 28-31), or
;            AC = 1 at the end of the folder, or an sd_read error.
;            Deleted entries, long name parts and the volume name are
;            skipped; "." and ".." (in a folder other than the root) are
;            not.
;   changes: R2-R5, X, Y, T0-T7, IO_T0-IO_T3, IO_TMP
;   clocks:  about 1,000, or 140,000 when it reads the next sector
; ------------------------------------------------------------
fs_next:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [SAVE_AC], ac
    ld   FSV, y
    ld   V_ONDIR, x
    ld   [y,x], ac
    bne  fn_loop
    ld   LINK_LO, x
    ld   fs_r25, [x]
    ld   LINK_HI, x
    ld   fs_r25 >> 8, [x]
    ld   fs_cwd >> 8, y
    jmp  fs_cwd
fs_r25:
    bne  fn_ret
fn_loop:
    ld   FSV, y
    ld   V_DIRI, x
    ld   [y,x], ac
    xor  16, ac
    bne  fn_have
    ld   FSB, ac                ; read the next 16 entries
    ld   ac, [R5]
    clr  ac
    ld   ac, [R4]
    ld   LINK_LO, x
    ld   fs_r26, [x]
    ld   LINK_HI, x
    ld   fs_r26 >> 8, [x]
    ld   fs_snext >> 8, y
    jmp  fs_snext
fs_r26:
    bne  fn_ret
    ld   FSV, y
    ld   V_FATC + 3, x          ; no FAT sector in the buffer now
    ld   0xFF, [y,x]
    ld   V_DIRI, x
    ld   0, [y,x]
fn_have:
    ld   V_DIRI, x
    ld   [y,x], ac
    ld   ac, [IO_T0]
    inc
    ld   ac, [y,x]
    ld   [IO_T0], ac            ; entry n is at FS_BUF + n * 32
    and  8, ac
    beq  fn_p0
    ld   FSB + 1, ac
    bra  fn_p
fn_p0:
    ld   FSB, ac
fn_p:
    ld   ac, [IO_T1]
    ld   [IO_T0], ac
    and  7, ac
    shl
    shl
    shl
    shl
    shl
    ld   ac, [IO_T0]
    ld   ac, x
    ld   [IO_T1], y
    ld   [y,x], ac
    beq  fn_end                 ; 00: no more entries
    xor  0xE5, ac
    beq  fn_loop                ; E5: deleted
    ld   [IO_T0], ac
    add  11, x
    ld   [y,x], ac
    and  0x0F, ac
    xor  0x0F, ac
    beq  fn_loop                ; a part of a long name
    ld   [y,x], ac
    and  0x08, ac
    bne  fn_loop                ; the volume name
    clr  ac
    ld   ac, [IO_T2]
fn_copy:
    ld   [IO_T0], ac
    add  [IO_T2], x
    ld   [IO_T1], y
    ld   [y,x], ac
    ld   ac, [IO_T3]
    ld   [IO_T2], ac
    add  V_ENTRY, x
    ld   FSV, y
    ld   [IO_T3], ac
    ld   ac, [y,x]
    ld   [IO_T2], ac
    inc
    ld   ac, [IO_T2]
    xor  32, ac
    bne  fn_copy
    ld   FS_ENTRY & 0xFF, ac
    ld   ac, [R0]
    ld   FS_ENTRY >> 8, ac
    ld   ac, [R1]
    clr  ac
fn_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave
fn_end:
    ld   FSV, y                 ; and stay at the end
    ld   V_DIRI, x
    ld   16, [y,x]
    ld   V_SSEC, x
    ld   0, [y,x]
    ld   V_SMODE, x
    ld   1, [y,x]
    ld   1, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave


; ============================================================
; Pages 13-14: fs_open
; ============================================================
#addr LIB2_CODE + 0xD00

; ------------------------------------------------------------
; fs_open - find a name in the current folder and open it
;   in:      R1:R0 = the name, ending with a 00 byte: "GAME.BIN",
;            "readme.txt" (case does not matter), "GAMES" (a folder),
;            ".." (the folder above)
;   out:     AC = 0: a file is open for fs_read (FS_REM = its size), or
;            a folder is now the current folder; FS_ENTRY = its folder
;            entry.  AC = 2 not found, 8 not mounted, or an sd_read
;            error.
;   changes: R0-R5, X, Y, T0-T7, IO_T0-IO_T3, IO_TMP
;   clocks:  about 1,000 per entry passed, plus 140,000 per sector
; ------------------------------------------------------------
fs_open:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [SAVE_AC], ac
    ld   LINK_LO, x
    ld   fs_r27, [x]
    ld   LINK_HI, x
    ld   fs_r27 >> 8, [x]
    ld   fs_cwd >> 8, y
    jmp  fs_cwd
fs_r27:
    beq  fo_name
    ld   lib_leave >> 8, y
    jmp  lib_leave
fo_name:
    ld   FSV, y                 ; the name as 11 characters
    ld   V_NAME, x
fo_fill:
    ld   0x20, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    xor  V_NAME + 11, ac
    bne  fo_fill
    clr  ac
    ld   ac, [IO_T1]            ; next place in the name
    ld   8, ac
    ld   ac, [IO_T2]            ; end of this part (8, then 11)
fo_char:
    ld   [R0], x
    ld   [R1], y
    ld   [y,x], ac
    beq  fo_go
    ld   ac, [IO_T3]
    ld   [R0], ac
    inc
    ld   ac, [R0]
    bne  fo_nc
    ld   [R1], ac
    inc
    ld   ac, [R1]
fo_nc:
    ld   [IO_T3], ac
    xor  0x2E, ac
    bne  fo_put                 ; not "."
    ld   [IO_T1], ac
    beq  fo_put                 ; a leading "." is part of the name
    ld   FSV, y
    ld   V_NAME, x
    ld   [y,x], ac
    xor  0x2E, ac
    beq  fo_put                 ; so is the second "." of ".."
    ld   8, ac                  ; the extension
    ld   ac, [IO_T1]
    ld   11, ac
    ld   ac, [IO_T2]
    bra  fo_char
fo_put:
    ld   [IO_T1], ac
    sub  [IO_T2], ac
    bge  fo_char                ; too long: drop it
    ld   [IO_T3], ac
    sub  0x61, ac
    blt  fo_st
    sub  26, ac
    bge  fo_st
    ld   [IO_T3], ac            ; a-z: upper case
    sub  0x20, ac
    ld   ac, [IO_T3]
fo_st:
    ld   FSV, y
    ld   [IO_T1], ac
    add  V_NAME, x
    inc
    ld   ac, [IO_T1]
    ld   [IO_T3], ac
    ld   ac, [y,x]
    bra  fo_char
fo_go:
    ld   fo_find >> 8, y
    jmp  fo_find

#addr LIB2_CODE + 0xE00
fo_find:
    ld   LINK_LO, x
    ld   fs_r28, [x]
    ld   LINK_HI, x
    ld   fs_r28 >> 8, [x]
    ld   fs_next >> 8, y
    jmp  fs_next
fs_r28:
    bne  fo_nf
    clr  ac
    ld   ac, [IO_T2]
fo_cmp:
    ld   [IO_T2], ac
    add  V_ENTRY, x
    ld   FSV, y
    ld   [y,x], ac
    ld   ac, [IO_T3]
    ld   [IO_T2], ac
    add  V_NAME, x
    ld   [y,x], ac
    xor  [IO_T3], ac
    bne  fo_find
    ld   [IO_T2], ac
    inc
    ld   ac, [IO_T2]
    xor  11, ac
    bne  fo_cmp
    ld   V_ENTRY + 28, ac       ; found: the size
    ld   LINK_LO, x
    ld   fs_r29, [x]
    ld   LINK_HI, x
    ld   fs_r29 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fs_r29:
    ld   V_REM, ac
    ld   LINK_LO, x
    ld   fs_r30, [x]
    ld   LINK_HI, x
    ld   fs_r30 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r30:
    ld   V_ENTRY + 20, ac       ; the first cluster, high word
    ld   LINK_LO, x
    ld   fs_r31, [x]
    ld   LINK_HI, x
    ld   fs_r31 >> 8, [x]
    ld   fs_getb >> 8, y
    jmp  fs_getb
fs_r31:
    ld   V_ENTRY + 26, ac       ; and low word
    ld   LINK_LO, x
    ld   fs_r32, [x]
    ld   LINK_HI, x
    ld   fs_r32 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fs_r32:
    ld   [T4], ac
    ld   ac, [T2]
    ld   [T5], ac
    ld   ac, [T3]
    ld   FSV, y
    ld   V_TYPE, x
    ld   [y,x], ac
    xor  32, ac
    beq  fo_32
    clr  ac                     ; FAT16: no high word
    ld   ac, [T2]
    ld   ac, [T3]
fo_32:
    ld   FSV, y
    ld   V_ENTRY + 11, x
    ld   [y,x], ac
    and  0x10, ac
    beq  fo_file
    ld   V_DCLUS, ac            ; a folder: the current folder now (".."
    ld   LINK_LO, x
    ld   fs_r33, [x]
    ld   LINK_HI, x
    ld   fs_r33 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r33:
    ld   LINK_LO, x
    ld   fs_r34, [x]
    ld   LINK_HI, x
    ld   fs_r34 >> 8, [x]
    ld   fs_cwd >> 8, y
    jmp  fs_cwd
fs_r34:
    ld   lib_leave >> 8, y
    jmp  lib_leave
fo_file:
    ld   LINK_LO, x
    ld   fs_r35, [x]
    ld   LINK_HI, x
    ld   fs_r35 >> 8, [x]
    ld   fs_chain >> 8, y
    jmp  fs_chain
fs_r35:
    ld   FSV, y
    ld   V_ONDIR, x
    ld   0, [y,x]
    clr  ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
fo_nf:
    xor  1, ac
    beq  fo_nf2
    xor  1, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
fo_nf2:
    ld   2, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave


; ============================================================
; Page 15: fs_read, fs_load
; ============================================================
#addr LIB2_CODE + 0xF00

; ------------------------------------------------------------
; fs_read - read the next 512 bytes of the open file
;   in:      R5:R4 = buffer address (512 bytes)
;   out:     AC = 0 and R5:R4 = buffer + 512, FS_REM = bytes still to
;            read; or AC = 1 at the end of the file, or an sd_read
;            error.  The last sector is read whole, so the buffer gets
;            up to 511 bytes past the end of the file.
;   changes: R0-R3, X, Y, T0-T7, IO_T0-IO_T3, IO_TMP
;   clocks:  about 160,000 (6.5 ms, about 75 KB/s)
; ------------------------------------------------------------
fs_read:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [SAVE_AC], ac
    ld   V_REM, ac
    ld   LINK_LO, x
    ld   fs_r36, [x]
    ld   LINK_HI, x
    ld   fs_r36 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fs_r36:
    ld   [T0], ac
    or   [T1], ac
    or   [T2], ac
    or   [T3], ac
    beq  rd_eof
    ld   LINK_LO, x
    ld   fs_r37, [x]
    ld   LINK_HI, x
    ld   fs_r37 >> 8, [x]
    ld   fs_snext >> 8, y
    jmp  fs_snext
fs_r37:
    bne  rd_ret
    ld   V_REM, ac
    ld   LINK_LO, x
    ld   fs_r38, [x]
    ld   LINK_HI, x
    ld   fs_r38 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fs_r38:
    ld   [T3], ac
    or   [T2], ac
    bne  rd_sub
    ld   [T1], ac
    and  0xFE, ac
    bne  rd_sub
    clr  ac                     ; less than 512 left: none now
    ld   ac, [T0]
    ld   ac, [T1]
    bra  rd_put
rd_sub:
    ld   [T1], ac               ; 512 fewer
    sub  2, ac
    ld   ac, [T1]
    and  0xFE, ac
    xor  0xFE, ac
    bne  rd_put
    ld   [T2], ac
    dec
    ld   ac, [T2]
    xor  0xFF, ac
    bne  rd_put
    ld   [T3], ac
    dec
    ld   ac, [T3]
rd_put:
    ld   V_REM, ac
    ld   LINK_LO, x
    ld   fs_r39, [x]
    ld   LINK_HI, x
    ld   fs_r39 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r39:
    clr  ac
rd_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave
rd_eof:
    ld   1, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ------------------------------------------------------------
; fs_load - load a file from the current folder into memory
;   in:      R1:R0 = the name, as fs_open; R5:R4 = where to load it
;   out:     AC = 0 when loaded (R5:R4 = past the last sector read;
;            FS_ENTRY + 28 = the size), or an error as fs_open, fs_read
;   changes: R0-R3, X, Y, T0-T7, IO_T0-IO_T3, IO_TMP
;   clocks:  about 160,000 per 512 bytes, plus the search
;   Whole sectors are written: up to 511 bytes past the end of the file.
; ------------------------------------------------------------
fs_load:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [SAVE_AC], ac
    ld   FSV, y
    ld   V_LBUF, x
    ld   [R4], ac
    ld   ac, [y,x]
    ld   V_LBUF + 1, x
    ld   [R5], ac
    ld   ac, [y,x]
    ld   LINK_LO, x
    ld   fs_r40, [x]
    ld   LINK_HI, x
    ld   fs_r40 >> 8, [x]
    ld   fs_open >> 8, y
    jmp  fs_open
fs_r40:
    bne  ld_ret
    ld   FSV, y
    ld   V_LBUF, x
    ld   [y,x], ac
    ld   ac, [R4]
    ld   V_LBUF + 1, x
    ld   [y,x], ac
    ld   ac, [R5]
ld_loop:
    ld   LINK_LO, x
    ld   fs_r41, [x]
    ld   LINK_HI, x
    ld   fs_r41 >> 8, [x]
    ld   fs_read >> 8, y
    jmp  fs_read
fs_r41:
    beq  ld_loop
    sub  1, ac
    beq  ld_ret
    add  1, ac
ld_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave


; ============================================================
; Pages 16-18: fs_mount
; ============================================================
#addr LIB2_CODE + 0x1000

; ------------------------------------------------------------
; fs_mount - find the FAT file system on the SD card
;   in:      - (sd_init first)
;   out:     AC = 0 when mounted (the root is the current folder), or 9 no FAT
;            file system, 10 FAT12, or an sd_read error
;   changes: R0-R5, X, Y, T0-T7, IO_T0-IO_T3, IO_TMP
;   clocks:  about 130,000 (one sector read), 260,000 with a
;            partition table
;   Takes the first partition of a partition table (MBR), or a card
;   formatted without one.
; ------------------------------------------------------------
fs_mount:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [SAVE_AC], ac
    ld   FSV, y
    ld   V_TYPE, x
    ld   0, [y,x]
    ld   V_FATC + 3, x
    ld   0xFF, [y,x]
    clr  ac                     ; sector 0
    ld   ac, [R0]
    ld   ac, [R1]
    ld   ac, [R2]
    ld   ac, [R3]
    ld   ac, [R4]
    ld   FSB, ac
    ld   ac, [R5]
    ld   LINK_LO, x
    ld   fs_r42, [x]
    ld   LINK_HI, x
    ld   fs_r42 >> 8, [x]
    ld   sd_read >> 8, y
    jmp  sd_read
fs_r42:
    bne  mt_ret
    ld   FSB, y                 ; a boot sector starts with a jump
    clr  x
    ld   [y,x], ac
    xor  0xEB, ac
    beq  mt_vbr
    ld   [y,x], ac
    xor  0xE9, ac
    beq  mt_vbr
    ld   FSB + 1, y             ; else a partition table: 55 AA at the end
    ld   0xFE, x
    ld   [y,x], ac
    xor  0x55, ac
    bne  mt_nofs
    ld   0xFF, x
    ld   [y,x], ac
    xor  0xAA, ac
    bne  mt_nofs
    ld   0xC2, x                ; the first partition's type, not 0
    ld   [y,x], ac
    beq  mt_nofs
    ld   0xC6, ac               ; and its first sector
    ld   LINK_LO, x
    ld   fs_r43, [x]
    ld   LINK_HI, x
    ld   fs_r43 >> 8, [x]
    ld   fs_bget1 >> 8, y
    jmp  fs_bget1
fs_r43:
    ld   [T4], ac
    ld   ac, [T0]
    ld   ac, [R0]
    ld   [T5], ac
    ld   ac, [T1]
    ld   ac, [R1]
    ld   [T6], ac
    ld   ac, [T2]
    ld   ac, [R2]
    ld   [T7], ac
    ld   ac, [T3]
    ld   ac, [R3]
    ld   V_PART, ac
    ld   LINK_LO, x
    ld   fs_r44, [x]
    ld   LINK_HI, x
    ld   fs_r44 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r44:
    clr  ac
    ld   ac, [R4]
    ld   FSB, ac
    ld   ac, [R5]
    ld   LINK_LO, x
    ld   fs_r45, [x]
    ld   LINK_HI, x
    ld   fs_r45 >> 8, [x]
    ld   sd_read >> 8, y
    jmp  sd_read
fs_r45:
    bne  mt_ret
    ld   mt_bpb >> 8, y
    jmp  mt_bpb
mt_vbr:
    clr  ac                     ; no partition table: the volume starts at 0
    ld   ac, [T0]
    ld   ac, [T1]
    ld   ac, [T2]
    ld   ac, [T3]
    ld   V_PART, ac
    ld   LINK_LO, x
    ld   fs_r46, [x]
    ld   LINK_HI, x
    ld   fs_r46 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r46:
    ld   mt_bpb >> 8, y
    jmp  mt_bpb
mt_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave
mt_nofs:
    ld   9, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave

#addr LIB2_CODE + 0x1100
mt_bpb:                         ; the boot sector is in FS_BUF
    ld   FSB, y
    ld   0x0B, x                ; 512 bytes per sector
    ld   [y,x], ac
    bne  mb_nofs
    ld   0x0C, x
    ld   [y,x], ac
    xor  2, ac
    bne  mb_nofs
    ld   0x0D, x                ; sectors per cluster
    ld   [y,x], ac
    beq  mb_nofs
    ld   ac, [IO_T0]
    ld   FSV, y
    ld   V_SPC, x
    ld   ac, [y,x]
    clr  ac
    ld   ac, [IO_T1]
mb_sh:
    ld   [IO_T0], ac            ; its log2
    xor  1, ac
    beq  mb_shd
    ld   [IO_T0], ac
    shr  ac
    ld   ac, [IO_T0]
    ld   [IO_T1], ac
    inc
    ld   ac, [IO_T1]
    bra  mb_sh
mb_shd:
    ld   [IO_T1], ac
    ld   V_SHIFT, x
    ld   ac, [y,x]
    ld   V_PART, ac             ; the FAT: after the reserved sectors
    ld   LINK_LO, x
    ld   fs_r47, [x]
    ld   LINK_HI, x
    ld   fs_r47 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fs_r47:
    ld   0x0E, ac
    ld   LINK_LO, x
    ld   fs_r48, [x]
    ld   LINK_HI, x
    ld   fs_r48 >> 8, [x]
    ld   fs_bget >> 8, y
    jmp  fs_bget
fs_r48:
    clr  ac
    ld   ac, [T6]
    ld   ac, [T7]
    ld   LINK_LO, x
    ld   fs_r49, [x]
    ld   LINK_HI, x
    ld   fs_r49 >> 8, [x]
    ld   fs_add >> 8, y
    jmp  fs_add
fs_r49:
    ld   V_FAT, ac
    ld   LINK_LO, x
    ld   fs_r50, [x]
    ld   LINK_HI, x
    ld   fs_r50 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r50:
    ld   0x16, ac               ; FAT size: 16 bits (FAT16) or 32 bits
    ld   LINK_LO, x
    ld   fs_r51, [x]
    ld   LINK_HI, x
    ld   fs_r51 >> 8, [x]
    ld   fs_bget >> 8, y
    jmp  fs_bget
fs_r51:
    ld   [T4], ac
    or   [T5], ac
    beq  mb_32
    ld   FSB, y                 ; FAT16, unless it says FAT12
    ld   0x3A, x
    ld   [y,x], ac
    xor  0x32, ac
    bne  mb_16
    ld   0x39, x
    ld   [y,x], ac
    xor  0x31, ac
    beq  mb_12
mb_16:
    clr  ac
    ld   ac, [T6]
    ld   ac, [T7]
    ld   16, ac
    bra  mb_t
mb_32:
    ld   0x24, ac
    ld   LINK_LO, x
    ld   fs_r52, [x]
    ld   LINK_HI, x
    ld   fs_r52 >> 8, [x]
    ld   fs_bget >> 8, y
    jmp  fs_bget
fs_r52:
    ld   32, ac
mb_t:
    ld   FSV, y
    ld   V_TMPT, x
    ld   ac, [y,x]
    ld   FSB, y                 ; the data starts after all the FATs
    ld   0x10, x
    ld   [y,x], ac
    beq  mb_nofs
mb_fl:
    ld   ac, [IO_TMP]
    ld   LINK_LO, x
    ld   fs_r53, [x]
    ld   LINK_HI, x
    ld   fs_r53 >> 8, [x]
    ld   fs_add >> 8, y
    jmp  fs_add
fs_r53:
    ld   [IO_TMP], ac
    dec
    bne  mb_fl
    ld   mb_after >> 8, y
    jmp  mb_after
mb_nofs:
    ld   9, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
mb_12:
    ld   10, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave

#addr LIB2_CODE + 0x1200
mb_after:                       ; T0-T3 = the first sector after the FATs
    ld   FSV, y
    ld   V_TMPT, x
    ld   [y,x], ac
    xor  32, ac
    beq  mb_d32
    ld   V_ROOT, ac             ; FAT16: the root folder comes first,
    ld   LINK_LO, x
    ld   fs_r54, [x]
    ld   LINK_HI, x
    ld   fs_r54 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r54:
    ld   FSB, y
    ld   0x11, x
    ld   [y,x], ac
    shr  ac
    shr  ac
    shr  ac
    shr  ac
    ld   ac, [IO_T0]
    ld   0x12, x
    ld   [y,x], ac
    shl
    shl
    shl
    shl
    or   [IO_T0], ac
    ld   ac, [T4]
    ld   FSV, y
    ld   V_RSECS, x
    ld   ac, [y,x]
    clr  ac
    ld   ac, [T5]
    ld   ac, [T6]
    ld   ac, [T7]
    ld   LINK_LO, x
    ld   fs_r55, [x]
    ld   LINK_HI, x
    ld   fs_r55 >> 8, [x]
    ld   fs_add >> 8, y
    jmp  fs_add
fs_r55:
    ld   V_DATA, ac
    ld   LINK_LO, x
    ld   fs_r56, [x]
    ld   LINK_HI, x
    ld   fs_r56 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r56:
    bra  mb_done
mb_d32:
    ld   V_DATA, ac
    ld   LINK_LO, x
    ld   fs_r57, [x]
    ld   LINK_HI, x
    ld   fs_r57 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r57:
    ld   0x2C, ac               ; FAT32: the root folder's cluster
    ld   LINK_LO, x
    ld   fs_r58, [x]
    ld   LINK_HI, x
    ld   fs_r58 >> 8, [x]
    ld   fs_bget >> 8, y
    jmp  fs_bget
fs_r58:
    ld   [T4], ac
    ld   ac, [T0]
    ld   [T5], ac
    ld   ac, [T1]
    ld   [T6], ac
    ld   ac, [T2]
    ld   [T7], ac
    ld   ac, [T3]
    ld   V_ROOT, ac
    ld   LINK_LO, x
    ld   fs_r59, [x]
    ld   LINK_HI, x
    ld   fs_r59 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r59:
mb_done:
    clr  ac                     ; the root is the current folder
    ld   ac, [T0]
    ld   ac, [T1]
    ld   ac, [T2]
    ld   ac, [T3]
    ld   V_DCLUS, ac
    ld   LINK_LO, x
    ld   fs_r60, [x]
    ld   LINK_HI, x
    ld   fs_r60 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r60:
    ld   FSV, y
    ld   V_ONDIR, x
    ld   0, [y,x]
    ld   V_TMPT, x
    ld   [y,x], ac
    ld   V_TYPE, x
    ld   ac, [y,x]
    clr  ac
    ld   lib_leave >> 8, y
    jmp  lib_leave


; ============================================================
; Page 19: fs_root, the current folder
; ============================================================
#addr LIB2_CODE + 0x1300

; ------------------------------------------------------------
; fs_root - make the root folder the current folder
;   in:      -
;   out:     AC = 0, or 8 if no card is mounted
;   changes: X, Y, T0-T7, IO_T0-IO_T3, IO_TMP
;   clocks:  about 2,000
; ------------------------------------------------------------
fs_root:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [SAVE_AC], ac
    clr  ac
    ld   ac, [T0]
    ld   ac, [T1]
    ld   ac, [T2]
    ld   ac, [T3]
    ld   V_DCLUS, ac
    ld   LINK_LO, x
    ld   fs_r61, [x]
    ld   LINK_HI, x
    ld   fs_r61 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r61:
    ld   LINK_LO, x
    ld   fs_r62, [x]
    ld   LINK_HI, x
    ld   fs_r62 >> 8, [x]
    ld   fs_cwd >> 8, y
    jmp  fs_cwd
fs_r62:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; fs_cwd - start the reader at the beginning of the current folder
;   out: AC = 0, or 8 if no card is mounted
fs_cwd:
    ld   ac, [SAVE_AC]          ; PUSH_LINK
    ld   [SP], x
    ld   [LINK_HI], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, x
    ld   [LINK_LO], ac
    ld   ac, [x]
    ld   x, ac
    dec
    ld   ac, [SP]
    ld   [SAVE_AC], ac
    ld   FSV, y
    ld   V_DIRI, x
    ld   16, [y,x]
    ld   V_ONDIR, x
    ld   1, [y,x]
    ld   V_TYPE, x
    ld   [y,x], ac
    beq  cw_none
    ld   V_DCLUS, ac
    ld   LINK_LO, x
    ld   fs_r63, [x]
    ld   LINK_HI, x
    ld   fs_r63 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fs_r63:
    ld   [T0], ac
    or   [T1], ac
    or   [T2], ac
    or   [T3], ac
    bne  cw_chain               ; a folder below the root
    ld   FSV, y
    ld   V_TYPE, x
    ld   [y,x], ac
    xor  32, ac
    beq  cw_32
    ld   V_ROOT, ac             ; FAT16 root: its own sectors
    ld   LINK_LO, x
    ld   fs_r64, [x]
    ld   LINK_HI, x
    ld   fs_r64 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fs_r64:
    ld   V_SLBA, ac
    ld   LINK_LO, x
    ld   fs_r65, [x]
    ld   LINK_HI, x
    ld   fs_r65 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fs_r65:
    ld   FSV, y
    ld   V_RSECS, x
    ld   [y,x], ac
    ld   V_SSEC, x
    ld   ac, [y,x]
    ld   V_SMODE, x
    ld   1, [y,x]
    clr  ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
cw_32:
    ld   V_ROOT, ac             ; FAT32 root: a cluster chain
    ld   LINK_LO, x
    ld   fs_r66, [x]
    ld   LINK_HI, x
    ld   fs_r66 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fs_r66:
cw_chain:
    ld   LINK_LO, x
    ld   fs_r67, [x]
    ld   LINK_HI, x
    ld   fs_r67 >> 8, [x]
    ld   fs_chain >> 8, y
    jmp  fs_chain
fs_r67:
    clr  ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
cw_none:
    ld   8, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave

