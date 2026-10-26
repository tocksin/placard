; ============================================================
; made by asm_expand.py from placard_fsw.masm: change that file, then run
;     python3 asm_expand.py placard_fsw.masm
; ============================================================

; ============================================================
; placard_fsw.masm - Placard FAT file writing (the DOS image)
; ============================================================
;
; Writes files to the SD card the FAT reader (placard_fs.asm) mounted,
; FAT16 or FAT32:
;
;     fs_create    make an empty file in the current folder (a file of
;                  the same name is deleted first) and open it for writing
;     fs_write     append the next 512 bytes
;     fs_close     set the size and finish the file
;     fs_delete    delete a file
;     fs_save      create + write + close: a block of memory as a file
;
; Clusters are taken from the first free FAT entry after the file's last
; cluster (from cluster 2 for the first), every FAT is kept up to date
; after each cluster, and the folder entry is written when the file is
; created (name, no data) and again when it is closed (first cluster,
; size), so an unplugged card leaves an empty file, not a broken one.
; Folders are not made or deleted, a folder is never grown (error 11 when
; it is full), and FAT32's free-cluster count (FSInfo) is left as it is;
; a PC fixes that count by itself.  Dates are 2026-01-01 00:00.
;
; Between fs_create and fs_close only fs_write may be called: the other
; file routines (fs_next, fs_open, fs_read, fs_load, fs_delete) change the
; buffer and the reader's state.
;
; Errors (AC): 2 not found, 4, 6 and 7 from sd_write, 5 from sd_read,
; 8 not mounted, 11 folder full, 12 no file open for writing, 13 the name
; is a folder, 14 the card is full.
;
; The writer's state is in FS_VARS x6D-x7F (placard_fs.asm lists x00-x6C)
; and it uses FS_BUF for FAT and folder sectors.  The routines change
; R0-R5, X, Y, T0-T7, IO_T0-IO_T3 and IO_TMP, and use the stack like the
; reader (about 10 bytes).
;
; This is not in the library proper: it is part of the DOS image at
; FSW_CODE (xB000-xBFFF), reached by programs through the DOS vectors at
; x8010-x8020 (dos.masm, docs/DOS.md).  placard_lib.asm's jump table is
; unchanged.  asm_expand.py writes placard_fsw.asm from this file.
;
; Date: 10/25/2026
; ============================================================

V_WCLUS   = 0x6D        ; 4: the file's first cluster, 0 = none yet
V_WLAST   = 0x71        ; 4: the cluster being written
V_WSECT    = 0x75        ; 4: the next sector to write (V_WSLEFT > 0)
V_WSLEFT   = 0x79        ; sectors left in that cluster
V_WENT    = 0x7A        ; bit 7 = a file is open for writing, bits 3:0 =
                        ; its folder entry (0-15) in sector V_WESEC
V_WESEC   = 0x7B        ; 4: the folder sector holding its entry
V_WDIRTY  = 0x7F        ; 1 = FS_BUF holds a changed FAT sector (V_FATC)
V_WBUF    = 0x3B        ; 2: fs_write's caller's buffer (R5:R4) while it
                        ; works on the FAT (x3B-x3F are free in the reader)
V_WSAVE   = 0x3D        ; 2: fs_save's buffer address while fs_create works
FSW_CODE  = 0xB000      ; the code (the DOS image, docs/ROM.md)

E_NOFILE  = 12
E_FOLDER  = 13
E_FULL    = 14
E_DIRFULL = 11


; ============================================================
; leaf helpers
; ============================================================

#addr 0xB000
fw_putb:
    ld   ac, [FS_IDX]
    ld   ac, x
    ld   FSV, y
    ld   [T4], ac
    ld   ac, [y,x]
    ld   [FS_IDX], ac
    add  1, x
    ld   [T5], ac
    ld   ac, [y,x]
    ld   [FS_IDX], ac
    add  2, x
    ld   [T6], ac
    ld   ac, [y,x]
    ld   [FS_IDX], ac
    add  3, x
    ld   [T7], ac
    ld   ac, [y,x]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

fw_inc:
    ld   [T0], ac
    inc
    ld   ac, [T0]
    bne  fi_d
    ld   [T1], ac
    inc
    ld   ac, [T1]
    bne  fi_d
    ld   [T2], ac
    inc
    ld   ac, [T2]
    bne  fi_d
    ld   [T3], ac
    inc
    ld   ac, [T3]
fi_d:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

fw_cp47:
    ld   [T0], ac
    ld   ac, [T4]
    ld   [T1], ac
    ld   ac, [T5]
    ld   [T2], ac
    ld   ac, [T6]
    ld   [T3], ac
    ld   ac, [T7]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

fw_sub:
    ld   [T0], ac
    sub  [T4], ac
    ld   ac, [T0]
    ld   [T1], ac
    bcc  fsb_1
    sub  1, ac
    bcs  fsb_1z                 ; T1 was 0: T1 = FF - T5, borrow out
fsb_1:
    sub  [T5], ac
    ld   ac, [T1]
    ld   [T2], ac
    bcc  fsb_2
fsb_2c:
    sub  1, ac
    bcs  fsb_2z
fsb_2:
    sub  [T6], ac
    ld   ac, [T2]
    ld   [T3], ac
    bcc  fsb_3
fsb_3c:
    sub  1, ac
fsb_3:
    sub  [T7], ac
    ld   ac, [T3]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
fsb_1z:
    sub  [T5], ac
    ld   ac, [T1]
    ld   [T2], ac
    bra  fsb_2c
fsb_2z:
    sub  [T6], ac
    ld   ac, [T2]
    ld   [T3], ac
    bra  fsb_3c

fw_shr:
    ld   [T3], ac
    ld   ac, [IO_T0]
    shr  ac
    ld   ac, [T3]
    ld   [T2], ac
    ld   ac, [IO_T1]
    shr  ac
    ld   ac, [T2]
    ld   [IO_T0], ac
    and  1, ac
    beq  fsh_2
    ld   [T2], ac
    or   0x80, ac
    ld   ac, [T2]
fsh_2:
    ld   [T1], ac
    ld   ac, [IO_T0]
    shr  ac
    ld   ac, [T1]
    ld   [IO_T1], ac
    and  1, ac
    beq  fsh_1
    ld   [T1], ac
    or   0x80, ac
    ld   ac, [T1]
fsh_1:
    ld   [T0], ac
    shr  ac
    ld   ac, [T0]
    ld   [IO_T0], ac
    and  1, ac
    beq  fsh_0
    ld   [T0], ac
    or   0x80, ac
    ld   ac, [T0]
fsh_0:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

fw_lba:
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
    ld   [LINK_HI], y
    jmp  [LINK_LO]


#addr 0xB100
; FAT32: 28 bits)
fw_fatval:
    ld   FSV, y
    ld   V_OFF, x
    ld   [y,x], ac
    ld   ac, [FS_IDX]
    ld   V_OFFP, x
    ld   [y,x], ac
    ld   ac, [IO_T1]
    ld   [FS_IDX], x
    ld   [IO_T1], y
    ld   [y,x], ac
    ld   ac, [T4]
    ld   [FS_IDX], ac
    add  1, x
    ld   [y,x], ac
    ld   ac, [T5]
    clr  ac
    ld   ac, [T6]
    ld   ac, [T7]
    ld   FSV, y
    ld   V_TYPE, x
    ld   [y,x], ac
    xor  32, ac
    bne  fv_d
    ld   [FS_IDX], ac
    add  2, x
    ld   [IO_T1], y
    ld   [y,x], ac
    ld   ac, [T6]
    ld   [FS_IDX], ac
    add  3, x
    ld   [y,x], ac
    and  0x0F, ac
    ld   ac, [T7]
fv_d:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

fw_fatset:
    ld   FSV, y
    ld   V_WDIRTY, x
    ld   1, [y,x]
    ld   V_OFF, x
    ld   [y,x], ac
    ld   ac, [FS_IDX]
    ld   V_OFFP, x
    ld   [y,x], ac
    ld   ac, [IO_T1]
    ld   [FS_IDX], x
    ld   [IO_T1], y
    ld   [T4], ac
    ld   ac, [y,x]
    ld   [FS_IDX], ac
    add  1, x
    ld   [T5], ac
    ld   ac, [y,x]
    ld   FSV, y
    ld   V_TYPE, x
    ld   [y,x], ac
    xor  32, ac
    bne  fst_d
    ld   [FS_IDX], ac
    add  2, x
    ld   [IO_T1], y
    ld   [T6], ac
    ld   ac, [y,x]
    ld   [FS_IDX], ac
    add  3, x
    ld   [T7], ac
    ld   ac, [y,x]
fst_d:
    ld   [LINK_HI], y
    jmp  [LINK_LO]

fw_ebase:
    ld   ac, [IO_T0]
    and  8, ac
    beq  eb_p0
    ld   FSB + 1, ac
    bra  eb_p
eb_p0:
    ld   FSB, ac
eb_p:
    ld   ac, [IO_T1]
    ld   [IO_T0], ac
    and  7, ac
    shl
    shl
    shl
    shl
    shl
    ld   ac, [IO_T0]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ============================================================
; fw_flush - write FS_BUF (a changed FAT sector, V_FATC) to every FAT
;   out: AC = 0, or an sd_write error.  Nothing when V_WDIRTY = 0.
; ============================================================
fe_sec:
    ld   V_SLBA, ac             ; the FAT sector, while the cluster is checked
    ld   LINK_LO, x             ; CALL fs_put
    ld   fsw_r26, [x]
    ld   LINK_HI, x
    ld   fsw_r26 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fsw_r26:
    ld   LINK_LO, x             ; CALL fw_maxc
    ld   fsw_r27, [x]
    ld   LINK_HI, x
    ld   fsw_r27 >> 8, [x]
    ld   fw_maxc >> 8, y
    jmp  fw_maxc
fsw_r27:
    bne  fe_full
    ld   V_SCLUS, ac            ; past the data area: the card is full
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r28, [x]
    ld   LINK_HI, x
    ld   fsw_r28 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r28:
    ld   V_MAXC, ac
    ld   LINK_LO, x             ; CALL fs_getb
    ld   fsw_r29, [x]
    ld   LINK_HI, x
    ld   fsw_r29 >> 8, [x]
    ld   fs_getb >> 8, y
    jmp  fs_getb
fsw_r29:
    ld   [T3], ac
    sub  [T7], ac
    bcs  fe_in
    bne  fe_fullc
    ld   [T2], ac
    sub  [T6], ac
    bcs  fe_in
    bne  fe_fullc
    ld   [T1], ac
    sub  [T5], ac
    bcs  fe_in
    bne  fe_fullc
    ld   [T0], ac
    sub  [T4], ac
    bcs  fe_in
fe_fullc:
    ld   E_FULL, ac
fe_full:
    ld   lib_leave >> 8, y
    jmp  lib_leave
fe_in:
    ld   fe_have >> 8, y
    jmp  fe_have


#addr 0xB200
fw_flush:
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
    ld   FSV, y
    ld   V_WDIRTY, x
    ld   [y,x], ac
    beq  ffl_ok
    ld   0, [y,x]
    ld   V_NFATS, x
    ld   [y,x], ac
    ld   V_TMPT, x              ; FATs left
    ld   ac, [y,x]
    ld   V_FATC, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r1, [x]
    ld   LINK_HI, x
    ld   fsw_r1 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r1:
    ld   V_REM, ac              ; the sector being written
    ld   LINK_LO, x             ; CALL fs_put
    ld   fsw_r2, [x]
    ld   LINK_HI, x
    ld   fsw_r2 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fsw_r2:
ffl_loop:
    ld   LINK_LO, x             ; CALL fw_lba
    ld   fsw_r3, [x]
    ld   LINK_HI, x
    ld   fsw_r3 >> 8, [x]
    ld   fw_lba >> 8, y
    jmp  fw_lba
fsw_r3:
    ld   LINK_LO, x             ; CALL sd_write
    ld   fsw_r4, [x]
    ld   LINK_HI, x
    ld   fsw_r4 >> 8, [x]
    ld   sd_write >> 8, y
    jmp  sd_write
fsw_r4:
    bne  ffl_ret
    ld   FSV, y
    ld   V_TMPT, x
    ld   [y,x], ac
    dec
    ld   ac, [y,x]
    beq  ffl_ok
    ld   V_REM, ac              ; the same sector in the next FAT
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r5, [x]
    ld   LINK_HI, x
    ld   fsw_r5 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r5:
    ld   V_FATSZ, ac
    ld   LINK_LO, x             ; CALL fs_getb
    ld   fsw_r6, [x]
    ld   LINK_HI, x
    ld   fsw_r6 >> 8, [x]
    ld   fs_getb >> 8, y
    jmp  fs_getb
fsw_r6:
    ld   LINK_LO, x             ; CALL fs_add
    ld   fsw_r7, [x]
    ld   LINK_HI, x
    ld   fsw_r7 >> 8, [x]
    ld   fs_add >> 8, y
    jmp  fs_add
fsw_r7:
    ld   V_REM, ac
    ld   LINK_LO, x             ; CALL fs_put
    ld   fsw_r8, [x]
    ld   LINK_HI, x
    ld   fsw_r8 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fsw_r8:
    bra  ffl_loop
ffl_ok:
    clr  ac
ffl_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ============================================================
; fw_maxc - V_MAXC = the first cluster number past the data area, from the
; boot sector: 2 + (volume sectors - data start) >> V_SHIFT.  Once per mount.
;   out: AC = 0 or an SD error
; ============================================================
fw_abort:
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
    ld   V_WCLUS, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r61, [x]
    ld   LINK_HI, x
    ld   fsw_r61 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r61:
    ld   FSV, y
    ld   7, ac
fab_c:
    add  V_WCLUS, x             ; V_WCLUS = V_WLAST = 0
    ld   0, [y,x]
    sub  1, ac
    bcc  fab_c
    ld   V_WSLEFT, x
    ld   0, [y,x]
    ld   fw_freech >> 8, y
    jmp  fw_freech

; ============================================================
; fs_delete - delete a file in the current folder
;   in:      R1:R0 = the name, as fs_open ("GAME.BIN")
;   out:     AC = 0, 2 not found, 8 not mounted, 13 a folder, or an SD error
;   changes: R0-R5, X, Y, T0-T7, IO_T0-IO_T3, IO_TMP
;   clocks:  the search (about 1,000 per entry plus 140,000 per sector),
;            then one sector write per 128 (FAT32) or 256 (FAT16)
;            clusters freed, times the number of FATs
; ============================================================

#addr 0xB300
fw_maxc:
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
    ld   V_MAXC, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r9, [x]
    ld   LINK_HI, x
    ld   fsw_r9 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r9:
    ld   [T0], ac
    or   [T1], ac
    or   [T2], ac
    or   [T3], ac
    bne  fmx_ok
    ld   LINK_LO, x             ; FS_BUF is about to be reused
    ld   fsw_r10, [x]
    ld   LINK_HI, x
    ld   fsw_r10 >> 8, [x]
    ld   fw_flush >> 8, y
    jmp  fw_flush
fsw_r10:
    bne  fmx_ret
    ld   V_PART, ac             ; the boot sector into FS_BUF
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r11, [x]
    ld   LINK_HI, x
    ld   fsw_r11 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r11:
    ld   LINK_LO, x             ; CALL fw_lba
    ld   fsw_r12, [x]
    ld   LINK_HI, x
    ld   fsw_r12 >> 8, [x]
    ld   fw_lba >> 8, y
    jmp  fw_lba
fsw_r12:
    ld   LINK_LO, x             ; CALL sd_read
    ld   fsw_r13, [x]
    ld   LINK_HI, x
    ld   fsw_r13 >> 8, [x]
    ld   sd_read >> 8, y
    jmp  sd_read
fsw_r13:
    bne  fmx_ret
    ld   FSV, y
    ld   V_FATC + 3, x          ; no FAT sector in the buffer now
    ld   0xFF, [y,x]
    ld   0x13, ac               ; total sectors, 16 bits ...
    ld   LINK_LO, x             ; CALL fs_bget
    ld   fsw_r14, [x]
    ld   LINK_HI, x
    ld   fsw_r14 >> 8, [x]
    ld   fs_bget >> 8, y
    jmp  fs_bget
fsw_r14:
    clr  ac
    ld   ac, [T6]
    ld   ac, [T7]
    ld   [T4], ac
    or   [T5], ac
    bne  fmx_tot
    ld   0x20, ac               ; ... or 32
    ld   LINK_LO, x             ; CALL fs_bget
    ld   fsw_r15, [x]
    ld   LINK_HI, x
    ld   fsw_r15 >> 8, [x]
    ld   fs_bget >> 8, y
    jmp  fs_bget
fsw_r15:
fmx_tot:
    ld   fmx_count >> 8, y
    jmp  fmx_count
fmx_ok:
    clr  ac
fmx_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave

fw_find:
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
    ld   LINK_LO, x             ; CALL fs_cwd
    ld   fsw_r47, [x]
    ld   LINK_HI, x
    ld   fsw_r47 >> 8, [x]
    ld   fs_cwd >> 8, y
    jmp  fs_cwd
fsw_r47:
    bne  ffd_ret
ffd_next:
    ld   LINK_LO, x             ; CALL fs_next
    ld   fsw_r48, [x]
    ld   LINK_HI, x
    ld   fsw_r48 >> 8, [x]
    ld   fs_next >> 8, y
    jmp  fs_next
fsw_r48:
    beq  ffd_cmp
    ld   ac, [IO_TMP]
    xor  1, ac
    bne  ffd_err
    ld   2, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
ffd_err:
    ld   [IO_TMP], ac
ffd_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave
ffd_cmp:
    clr  ac
    ld   ac, [IO_T2]
ffd_c:
    ld   [IO_T2], ac
    add  V_ENTRY, x
    ld   FSV, y
    ld   [y,x], ac
    ld   ac, [IO_T3]
    ld   [IO_T2], ac
    add  V_NAME, x
    ld   [y,x], ac
    xor  [IO_T3], ac
    bne  ffd_next
    ld   [IO_T2], ac
    inc
    ld   ac, [IO_T2]
    xor  11, ac
    bne  ffd_c
    clr  ac
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ============================================================
; fw_unlink - delete the file fw_find found: mark its entry, free its chain
;   out: AC = 0, 13 for a folder, or an SD error
; ============================================================
fmx_count:
    ld   V_PART, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r16, [x]
    ld   LINK_HI, x
    ld   fsw_r16 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r16:
    ld   LINK_LO, x             ; + the volume's first sector
    ld   fsw_r17, [x]
    ld   LINK_HI, x
    ld   fsw_r17 >> 8, [x]
    ld   fs_add >> 8, y
    jmp  fs_add
fsw_r17:
    ld   V_DATA, ac
    ld   LINK_LO, x             ; CALL fs_getb
    ld   fsw_r18, [x]
    ld   LINK_HI, x
    ld   fsw_r18 >> 8, [x]
    ld   fs_getb >> 8, y
    jmp  fs_getb
fsw_r18:
    ld   LINK_LO, x             ; - the data start = data sectors
    ld   fsw_r19, [x]
    ld   LINK_HI, x
    ld   fsw_r19 >> 8, [x]
    ld   fw_sub >> 8, y
    jmp  fw_sub
fsw_r19:
    ld   FSV, y
    ld   V_SHIFT, x
    ld   [y,x], ac
fmx_sh:
    beq  fmx_2
    ld   ac, [IO_TMP]
    ld   LINK_LO, x             ; CALL fw_shr
    ld   fsw_r20, [x]
    ld   LINK_HI, x
    ld   fsw_r20 >> 8, [x]
    ld   fw_shr >> 8, y
    jmp  fw_shr
fsw_r20:
    ld   [IO_TMP], ac
    dec
    bra  fmx_sh
fmx_2:
    ld   LINK_LO, x             ; clusters start at 2
    ld   fsw_r21, [x]
    ld   LINK_HI, x
    ld   fsw_r21 >> 8, [x]
    ld   fw_inc >> 8, y
    jmp  fw_inc
fsw_r21:
    ld   LINK_LO, x             ; CALL fw_inc
    ld   fsw_r22, [x]
    ld   LINK_HI, x
    ld   fsw_r22 >> 8, [x]
    ld   fw_inc >> 8, y
    jmp  fw_inc
fsw_r22:
    ld   V_MAXC, ac
    ld   LINK_LO, x             ; CALL fs_put
    ld   fsw_r23, [x]
    ld   LINK_HI, x
    ld   fsw_r23 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fsw_r23:
    clr  ac
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ============================================================
; fw_entry - FS_BUF = the FAT sector of cluster T0-T3 (written first if
; it was changed), V_OFFP:V_OFF = the entry's place, V_SCLUS = the cluster
;   out: AC = 0, 14 when the cluster is past the data area, or an SD error
; ============================================================
fs_delete:
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
    ld   FSV, y
    ld   V_TYPE, x
    ld   [y,x], ac
    bne  fd_m
    ld   8, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
fd_m:
    ld   LINK_LO, x             ; CALL fs_name
    ld   fsw_r62, [x]
    ld   LINK_HI, x
    ld   fsw_r62 >> 8, [x]
    ld   fs_name >> 8, y
    jmp  fs_name
fsw_r62:
    ld   LINK_LO, x             ; CALL fw_find
    ld   fsw_r63, [x]
    ld   LINK_HI, x
    ld   fsw_r63 >> 8, [x]
    ld   fw_find >> 8, y
    jmp  fw_find
fsw_r63:
    bne  fd_ret
    ld   LINK_LO, x             ; CALL fw_unlink
    ld   fsw_r64, [x]
    ld   LINK_HI, x
    ld   fsw_r64 >> 8, [x]
    ld   fw_unlink >> 8, y
    jmp  fw_unlink
fsw_r64:
fd_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ============================================================
; fs_create - make an empty file in the current folder and open it for
; fs_write; a file of the same name is deleted first
;   in:      R1:R0 = the name, as fs_open
;   out:     AC = 0 (the file exists, empty), 8 not mounted, 11 the folder
;            is full, 13 the name is a folder, or an SD error
;   changes: R0-R5, X, Y, T0-T7, IO_T0-IO_T3, IO_TMP
;   clocks:  the folder search (about 1,000 per entry plus 140,000 per
;            sector) and one sector write; the delete when it replaces
; ============================================================
fs_write:
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
    ld   FSV, y
    ld   V_WENT, x
    ld   [y,x], ac
    blt  fw_open
    ld   E_NOFILE, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
fw_open:
    ld   V_WBUF, x              ; the caller's buffer, kept while the FAT
    ld   [R4], ac               ; work changes R0-R5
    ld   ac, [y,x]
    ld   V_WBUF + 1, x
    ld   [R5], ac
    ld   ac, [y,x]
    ld   V_WSLEFT, x
    ld   [y,x], ac
    bne  fw_sec
    ld   fw_newc >> 8, y
    jmp  fw_newc
fw_sec:
    ld   fw_sec2 >> 8, y
    jmp  fw_sec2


#addr 0xB500
fw_entry:
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
    ld   V_SCLUS, ac
    ld   LINK_LO, x             ; CALL fs_put
    ld   fsw_r24, [x]
    ld   LINK_HI, x
    ld   fsw_r24 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fsw_r24:
    ld   FSV, y
    ld   V_TYPE, x
    ld   [y,x], ac
    xor  32, ac
    beq  fe_32
    ld   [T0], ac               ; FAT16: entry at byte cluster * 2
    shl
    ld   V_OFF, x
    ld   ac, [y,x]
    ld   [T0], ac
    blt  fe_p1
    ld   FSB, ac
    bra  fe_p
fe_p1:
    ld   FSB + 1, ac
fe_p:
    ld   V_OFFP, x
    ld   ac, [y,x]
    ld   [T1], ac               ; sector = cluster >> 8
    ld   ac, [T0]
    ld   [T2], ac
    ld   ac, [T1]
    ld   [T3], ac
    ld   ac, [T2]
    clr  ac
    ld   ac, [T3]
    ld   fe_sec >> 8, y
    jmp  fe_sec
fe_32:
    ld   [T0], ac               ; FAT32: entry at byte (cluster & 7F) * 4
    shl
    shl
    ld   V_OFF, x
    ld   ac, [y,x]
    ld   [T0], ac
    and  0x40, ac
    beq  fe_q0
    ld   FSB + 1, ac
    bra  fe_q
fe_q0:
    ld   FSB, ac
fe_q:
    ld   V_OFFP, x
    ld   ac, [y,x]
    ld   LINK_LO, x             ; sector = cluster >> 7
    ld   fsw_r25, [x]
    ld   LINK_HI, x
    ld   fsw_r25 >> 8, [x]
    ld   fs_shl >> 8, y
    jmp  fs_shl
fsw_r25:
    ld   [T1], ac
    ld   ac, [T0]
    ld   [T2], ac
    ld   ac, [T1]
    ld   [T3], ac
    ld   ac, [T2]
    clr  ac
    ld   ac, [T3]
    ld   fe_sec >> 8, y
    jmp  fe_sec

fw_sec2:
    ld   V_WSECT, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r90, [x]
    ld   LINK_HI, x
    ld   fsw_r90 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r90:
    ld   [T0], ac
    ld   ac, [R0]
    ld   [T1], ac
    ld   ac, [R1]
    ld   [T2], ac
    ld   ac, [R2]
    ld   [T3], ac
    ld   ac, [R3]
    ld   FSV, y
    ld   V_WBUF, x
    ld   [y,x], ac
    ld   ac, [R4]
    ld   V_WBUF + 1, x
    ld   [y,x], ac
    ld   ac, [R5]
    ld   LINK_LO, x             ; CALL sd_write
    ld   fsw_r91, [x]
    ld   LINK_HI, x
    ld   fsw_r91 >> 8, [x]
    ld   sd_write >> 8, y
    jmp  sd_write
fsw_r91:
    bne  fws_ret
    ld   V_WSECT, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r92, [x]
    ld   LINK_HI, x
    ld   fsw_r92 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r92:
    ld   LINK_LO, x             ; CALL fw_inc
    ld   fsw_r93, [x]
    ld   LINK_HI, x
    ld   fsw_r93 >> 8, [x]
    ld   fw_inc >> 8, y
    jmp  fw_inc
fsw_r93:
    ld   V_WSECT, ac
    ld   LINK_LO, x             ; CALL fs_put
    ld   fsw_r94, [x]
    ld   LINK_HI, x
    ld   fsw_r94 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fsw_r94:
    ld   FSV, y
    ld   V_WSLEFT, x
    ld   [y,x], ac
    dec
    ld   ac, [y,x]
    clr  ac
fws_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ============================================================
; fs_close - finish the file being written: its size and first cluster
; go into its folder entry
;   in:      R3:R0 = the size in bytes (R0 lowest); at most the bytes
;            written
;   out:     AC = 0, 12 no file open, or an SD error
;   changes: R0-R5, X, Y, T0-T7, IO_T0-IO_T3, IO_TMP
;   clocks:  one sector read and one write, plus the FAT writes if a
;            cluster was taken since the last fs_write
; ============================================================

#addr 0xB600
; V_SLBA = its sector in the FAT
fe_have:
    ld   V_SLBA, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r30, [x]
    ld   LINK_HI, x
    ld   fsw_r30 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r30:
    ld   V_FAT, ac              ; its address on the card
    ld   LINK_LO, x             ; CALL fs_getb
    ld   fsw_r31, [x]
    ld   LINK_HI, x
    ld   fsw_r31 >> 8, [x]
    ld   fs_getb >> 8, y
    jmp  fs_getb
fsw_r31:
    ld   LINK_LO, x             ; CALL fs_add
    ld   fsw_r32, [x]
    ld   LINK_HI, x
    ld   fsw_r32 >> 8, [x]
    ld   fs_add >> 8, y
    jmp  fs_add
fsw_r32:
    ld   V_FATC, ac             ; already in FS_BUF?
    ld   LINK_LO, x             ; CALL fs_getb
    ld   fsw_r33, [x]
    ld   LINK_HI, x
    ld   fsw_r33 >> 8, [x]
    ld   fs_getb >> 8, y
    jmp  fs_getb
fsw_r33:
    ld   [T0], ac
    xor  [T4], ac
    bne  fe_load
    ld   [T1], ac
    xor  [T5], ac
    bne  fe_load
    ld   [T2], ac
    xor  [T6], ac
    bne  fe_load
    ld   [T3], ac
    xor  [T7], ac
    bne  fe_load
    clr  ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
fe_load:
    ld   V_SLBA, ac             ; the sector wanted, while the old one is written
    ld   LINK_LO, x             ; CALL fs_put
    ld   fsw_r34, [x]
    ld   LINK_HI, x
    ld   fsw_r34 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fsw_r34:
    ld   LINK_LO, x             ; CALL fw_flush
    ld   fsw_r35, [x]
    ld   LINK_HI, x
    ld   fsw_r35 >> 8, [x]
    ld   fw_flush >> 8, y
    jmp  fw_flush
fsw_r35:
    bne  fe_ret
    ld   V_SLBA, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r36, [x]
    ld   LINK_HI, x
    ld   fsw_r36 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r36:
    ld   V_FATC, ac
    ld   LINK_LO, x             ; CALL fs_put
    ld   fsw_r37, [x]
    ld   LINK_HI, x
    ld   fsw_r37 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fsw_r37:
    ld   LINK_LO, x             ; CALL fw_lba
    ld   fsw_r38, [x]
    ld   LINK_HI, x
    ld   fsw_r38 >> 8, [x]
    ld   fw_lba >> 8, y
    jmp  fw_lba
fsw_r38:
    ld   LINK_LO, x             ; CALL sd_read
    ld   fsw_r39, [x]
    ld   LINK_HI, x
    ld   fsw_r39 >> 8, [x]
    ld   sd_read >> 8, y
    jmp  sd_read
fsw_r39:
    beq  fe_ret
    ld   ac, [IO_TMP]
    ld   FSV, y                 ; no FAT sector in the buffer now
    ld   V_FATC + 3, x
    ld   0xFF, [y,x]
    ld   [IO_TMP], ac
fe_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ============================================================
; fw_alloc - take a free cluster: T0-T3 = it, its FAT entry = end of chain
;   The search starts after the file's last cluster (V_WLAST), or at 2,
;   and goes round once.
;   out: AC = 0, 14 when the card is full, or an SD error
; ============================================================
fsv_abort:
    ld   FSV, y
    ld   V_WBUF, x
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL fw_abort
    ld   fsw_r109, [x]
    ld   LINK_HI, x
    ld   fsw_r109 >> 8, [x]
    ld   fw_abort >> 8, y
    jmp  fw_abort
fsw_r109:
    clr  ac
    ld   ac, [R0]
    ld   ac, [R1]
    ld   ac, [R2]
    ld   ac, [R3]
    ld   LINK_LO, x             ; CALL fs_close
    ld   fsw_r110, [x]
    ld   LINK_HI, x
    ld   fsw_r110 >> 8, [x]
    ld   fs_close >> 8, y
    jmp  fs_close
fsw_r110:
    ld   FSV, y
    ld   V_WBUF, x
    ld   [y,x], ac
    ld   lib_leave >> 8, y
    jmp  lib_leave

#addr 0xB700
fw_alloc:
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
    ld   FSV, y
    ld   V_SMODE, x             ; 1 once the search has started over at 2
    ld   0, [y,x]
    ld   V_WLAST, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r40, [x]
    ld   LINK_HI, x
    ld   fsw_r40 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r40:
    ld   [T0], ac
    or   [T1], ac
    or   [T2], ac
    or   [T3], ac
    bne  fa_scan
fa_from2:
    ld   FSV, y
    ld   V_SMODE, x
    ld   1, [y,x]
    clr  ac
    ld   ac, [T1]
    ld   ac, [T2]
    ld   ac, [T3]
    ld   2, ac
    ld   ac, [T0]
fa_scan:
    ld   LINK_LO, x             ; CALL fw_entry
    ld   fsw_r41, [x]
    ld   LINK_HI, x
    ld   fsw_r41 >> 8, [x]
    ld   fw_entry >> 8, y
    jmp  fw_entry
fsw_r41:
    beq  fa_look
    ld   ac, [IO_TMP]
    xor  E_FULL, ac
    bne  fa_fail
    ld   FSV, y
    ld   V_SMODE, x
    ld   [y,x], ac
    bne  fa_fail                ; the whole FAT seen: full
    bra  fa_from2
fa_fail:
    ld   [IO_TMP], ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
fa_look:
    ld   LINK_LO, x             ; CALL fw_fatval
    ld   fsw_r42, [x]
    ld   LINK_HI, x
    ld   fsw_r42 >> 8, [x]
    ld   fw_fatval >> 8, y
    jmp  fw_fatval
fsw_r42:
    ld   [T4], ac
    or   [T5], ac
    or   [T6], ac
    or   [T7], ac
    beq  fa_free
    ld   V_SCLUS, ac            ; in use: the next one
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r43, [x]
    ld   LINK_HI, x
    ld   fsw_r43 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r43:
    ld   LINK_LO, x             ; CALL fw_inc
    ld   fsw_r44, [x]
    ld   LINK_HI, x
    ld   fsw_r44 >> 8, [x]
    ld   fw_inc >> 8, y
    jmp  fw_inc
fsw_r44:
    bra  fa_scan
fa_free:
    ld   0xFF, ac               ; end of chain: FFFF or 0FFFFFFF
    ld   ac, [T4]
    ld   ac, [T5]
    ld   ac, [T6]
    ld   0x0F, ac
    ld   ac, [T7]
    ld   LINK_LO, x             ; CALL fw_fatset
    ld   fsw_r45, [x]
    ld   LINK_HI, x
    ld   fsw_r45 >> 8, [x]
    ld   fw_fatset >> 8, y
    jmp  fw_fatset
fsw_r45:
    ld   V_SCLUS, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r46, [x]
    ld   LINK_HI, x
    ld   fsw_r46 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r46:
    clr  ac
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ============================================================
; fw_find - find V_NAME in the current folder (fs_name first)
;   out: AC = 0 found (FS_ENTRY = the entry, FS_BUF = its sector V_DSEC,
;        V_DIRI - 1 = its place), 2 not found, or an error
; ============================================================

#addr 0xB800
fw_unlink:
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
    ld   FSV, y
    ld   V_ENTRY + 11, x
    ld   [y,x], ac
    and  0x10, ac
    beq  fu_file
    ld   E_FOLDER, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
fu_file:
    ld   V_DIRI, x
    ld   [y,x], ac
    dec
    ld   LINK_LO, x             ; CALL fw_ebase
    ld   fsw_r49, [x]
    ld   LINK_HI, x
    ld   fsw_r49 >> 8, [x]
    ld   fw_ebase >> 8, y
    jmp  fw_ebase
fsw_r49:
    ld   [IO_T0], x
    ld   [IO_T1], y
    ld   0xE5, [y,x]            ; deleted
    ld   V_DSEC, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r50, [x]
    ld   LINK_HI, x
    ld   fsw_r50 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r50:
    ld   LINK_LO, x             ; CALL fw_lba
    ld   fsw_r51, [x]
    ld   LINK_HI, x
    ld   fsw_r51 >> 8, [x]
    ld   fw_lba >> 8, y
    jmp  fw_lba
fsw_r51:
    ld   LINK_LO, x             ; CALL sd_write
    ld   fsw_r52, [x]
    ld   LINK_HI, x
    ld   fsw_r52 >> 8, [x]
    ld   sd_write >> 8, y
    jmp  sd_write
fsw_r52:
    bne  fu_ret
    ld   V_ENTRY + 26, ac       ; its first cluster, low word
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r53, [x]
    ld   LINK_HI, x
    ld   fsw_r53 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r53:
    ld   V_ENTRY + 20, ac       ; and high word (FAT32)
    ld   LINK_LO, x             ; CALL fs_getb
    ld   fsw_r54, [x]
    ld   LINK_HI, x
    ld   fsw_r54 >> 8, [x]
    ld   fs_getb >> 8, y
    jmp  fs_getb
fsw_r54:
    ld   FSV, y
    ld   V_TYPE, x
    ld   [y,x], ac
    xor  32, ac
    beq  fu_32
    clr  ac
    ld   ac, [T4]
    ld   ac, [T5]
fu_32:
    ld   [T4], ac
    ld   ac, [T2]
    ld   [T5], ac
    and  0x0F, ac
    ld   ac, [T3]
    ld   fw_freech >> 8, y
    jmp  fw_freech
fu_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave


#addr 0xB900
fw_freech:
    ld   [T0], ac
    or   [T1], ac
    or   [T2], ac
    or   [T3], ac
    beq  fch_done
    ld   LINK_LO, x             ; CALL fw_entry
    ld   fsw_r55, [x]
    ld   LINK_HI, x
    ld   fsw_r55 >> 8, [x]
    ld   fw_entry >> 8, y
    jmp  fw_entry
fsw_r55:
    bne  fch_ret
    ld   LINK_LO, x             ; the next cluster
    ld   fsw_r56, [x]
    ld   LINK_HI, x
    ld   fsw_r56 >> 8, [x]
    ld   fw_fatval >> 8, y
    jmp  fw_fatval
fsw_r56:
    ld   V_SLBA, ac
    ld   LINK_LO, x             ; CALL fw_putb
    ld   fsw_r57, [x]
    ld   LINK_HI, x
    ld   fsw_r57 >> 8, [x]
    ld   fw_putb >> 8, y
    jmp  fw_putb
fsw_r57:
    clr  ac                     ; this one is free
    ld   ac, [T4]
    ld   ac, [T5]
    ld   ac, [T6]
    ld   ac, [T7]
    ld   LINK_LO, x             ; CALL fw_fatset
    ld   fsw_r58, [x]
    ld   LINK_HI, x
    ld   fsw_r58 >> 8, [x]
    ld   fw_fatset >> 8, y
    jmp  fw_fatset
fsw_r58:
    ld   V_SLBA, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r59, [x]
    ld   LINK_HI, x
    ld   fsw_r59 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r59:
    ld   FSV, y                 ; the end of the chain?
    ld   V_TYPE, x
    ld   [y,x], ac
    xor  32, ac
    beq  fch_32
    ld   [T1], ac               ; FAT16: FFF8-FFFF
    xor  0xFF, ac
    bne  fch_low
    bra  fch_t0
fch_32:
    ld   [T3], ac               ; FAT32: 0FFFFFF8-0FFFFFFF
    xor  0x0F, ac
    bne  fch_low
    ld   [T2], ac
    and  [T1], ac
    xor  0xFF, ac
    bne  fch_low
fch_t0:
    ld   [T0], ac
    and  0xF8, ac
    xor  0xF8, ac
    beq  fch_done
fch_low:
    ld   [T3], ac               ; 0 and 1 end a broken chain
    or   [T2], ac
    or   [T1], ac
    bne  fw_freech
    ld   [T0], ac
    and  0xFE, ac
    bne  fw_freech
fch_done:
    ld   LINK_LO, x             ; CALL fw_flush
    ld   fsw_r60, [x]
    ld   LINK_HI, x
    ld   fsw_r60 >> 8, [x]
    ld   fw_flush >> 8, y
    jmp  fw_flush
fsw_r60:
fch_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ============================================================
; fw_abort - give the clusters of the file being written back (a write
; failed): fs_close then leaves an empty file
;   out: AC = 0 or an SD error
; ============================================================

#addr 0xBA00
fs_create:
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
    ld   FSV, y
    ld   V_TYPE, x
    ld   [y,x], ac
    bne  fc_m
    ld   8, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
fc_m:
    ld   V_WENT, x              ; nothing open while this works
    ld   0, [y,x]
    ld   LINK_LO, x             ; CALL fs_name
    ld   fsw_r65, [x]
    ld   LINK_HI, x
    ld   fsw_r65 >> 8, [x]
    ld   fs_name >> 8, y
    jmp  fs_name
fsw_r65:
    ld   LINK_LO, x             ; CALL fw_find
    ld   fsw_r66, [x]
    ld   LINK_HI, x
    ld   fsw_r66 >> 8, [x]
    ld   fw_find >> 8, y
    jmp  fw_find
fsw_r66:
    beq  fc_del
    ld   ac, [IO_TMP]
    xor  2, ac
    beq  fc_free
    ld   [IO_TMP], ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
fc_del:
    ld   LINK_LO, x             ; CALL fw_unlink
    ld   fsw_r67, [x]
    ld   LINK_HI, x
    ld   fsw_r67 >> 8, [x]
    ld   fw_unlink >> 8, y
    jmp  fw_unlink
fsw_r67:
    bne  fc_ret
fc_free:
    ld   LINK_LO, x             ; a free entry: the first 00 or E5
    ld   fsw_r68, [x]
    ld   LINK_HI, x
    ld   fsw_r68 >> 8, [x]
    ld   fs_cwd >> 8, y
    jmp  fs_cwd
fsw_r68:
    bne  fc_ret
fc_sec:
    ld   V_SLBA, ac             ; the sector about to be read
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r69, [x]
    ld   LINK_HI, x
    ld   fsw_r69 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r69:
    ld   V_WESEC, ac
    ld   LINK_LO, x             ; CALL fs_put
    ld   fsw_r70, [x]
    ld   LINK_HI, x
    ld   fsw_r70 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fsw_r70:
    ld   FSB, ac
    ld   ac, [R5]
    clr  ac
    ld   ac, [R4]
    ld   LINK_LO, x             ; CALL fs_snext
    ld   fsw_r71, [x]
    ld   LINK_HI, x
    ld   fsw_r71 >> 8, [x]
    ld   fs_snext >> 8, y
    jmp  fs_snext
fsw_r71:
    beq  fc_look
    ld   ac, [IO_TMP]
    xor  1, ac
    beq  fc_dfull
    ld   [IO_TMP], ac
fc_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave
fc_dfull:
    ld   E_DIRFULL, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
fc_look:
    clr  ac
    ld   ac, [IO_T2]
fc_e:
    ld   [IO_T2], ac
    ld   LINK_LO, x             ; CALL fw_ebase
    ld   fsw_r72, [x]
    ld   LINK_HI, x
    ld   fsw_r72 >> 8, [x]
    ld   fw_ebase >> 8, y
    jmp  fw_ebase
fsw_r72:
    ld   [IO_T0], x
    ld   [IO_T1], y
    ld   [y,x], ac
    beq  fc_got
    xor  0xE5, ac
    beq  fc_got
    ld   [IO_T2], ac
    inc
    ld   ac, [IO_T2]
    xor  16, ac
    bne  fc_e
    bra  fc_sec
fc_got:
    ld   fc_fill >> 8, y
    jmp  fc_fill


#addr 0xBB00
fc_fill:
    clr  ac
    ld   ac, [IO_T3]
fcf_n:
    ld   [IO_T3], ac            ; the name, 11 characters
    add  V_NAME, x
    ld   FSV, y
    ld   [y,x], ac
    ld   ac, [T0]
    ld   [IO_T3], ac
    add  [IO_T0], x
    ld   [IO_T1], y
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [IO_T3], ac
    inc
    ld   ac, [IO_T3]
    xor  11, ac
    bne  fcf_n
fcf_z:
    ld   [IO_T3], ac            ; the rest 00
    add  [IO_T0], x
    ld   0, [y,x]
    ld   [IO_T3], ac
    inc
    ld   ac, [IO_T3]
    xor  32, ac
    bne  fcf_z
    ld   [IO_T0], ac
    add  11, x
    ld   0x20, [y,x]            ; a plain file
    ld   [IO_T0], ac
    add  16, x
    ld   0x21, [y,x]            ; made 2026-01-01
    ld   [IO_T0], ac
    add  17, x
    ld   0x5C, [y,x]
    ld   [IO_T0], ac
    add  24, x
    ld   0x21, [y,x]            ; written 2026-01-01
    ld   [IO_T0], ac
    add  25, x
    ld   0x5C, [y,x]
    ld   FSV, y
    ld   [IO_T2], ac
    or   0x80, ac
    ld   V_WENT, x              ; open for writing, entry IO_T2
    ld   ac, [y,x]
    ld   V_WESEC, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r73, [x]
    ld   LINK_HI, x
    ld   fsw_r73 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r73:
    ld   LINK_LO, x             ; CALL fw_lba
    ld   fsw_r74, [x]
    ld   LINK_HI, x
    ld   fsw_r74 >> 8, [x]
    ld   fw_lba >> 8, y
    jmp  fw_lba
fsw_r74:
    ld   LINK_LO, x             ; CALL sd_write
    ld   fsw_r75, [x]
    ld   LINK_HI, x
    ld   fsw_r75 >> 8, [x]
    ld   sd_write >> 8, y
    jmp  sd_write
fsw_r75:
    bne  fcf_ret
    ld   FSV, y
    ld   7, ac
fcf_c:
    add  V_WCLUS, x             ; V_WCLUS = V_WLAST = 0
    ld   0, [y,x]
    sub  1, ac
    bcc  fcf_c
    ld   V_WSLEFT, x
    ld   0, [y,x]
    ld   V_WDIRTY, x
    ld   0, [y,x]
    ld   V_FATC + 3, x          ; FS_BUF holds the folder sector
    ld   0xFF, [y,x]
    clr  ac
fcf_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ============================================================
; fs_write - append 512 bytes to the file being written
;   in:      R5:R4 = the bytes
;   out:     AC = 0 and R5:R4 + 512, 12 no file open, 14 card full, or
;            an SD error
;   changes: R0-R5, X, Y, T0-T7, IO_T0-IO_T3, IO_TMP
;   clocks:  about 130,000 (one sector write) plus the card's busy time;
;            a new cluster adds FAT reads and one write per FAT
; ============================================================

#addr 0xBC00
fw_newc:
    ld   LINK_LO, x             ; T0-T3 = a new cluster
    ld   fsw_r76, [x]
    ld   LINK_HI, x
    ld   fsw_r76 >> 8, [x]
    ld   fw_alloc >> 8, y
    jmp  fw_alloc
fsw_r76:
    bne  fw_ret
    ld   V_WSECT, ac             ; parked here
    ld   LINK_LO, x             ; CALL fs_put
    ld   fsw_r77, [x]
    ld   LINK_HI, x
    ld   fsw_r77 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fsw_r77:
    ld   V_WCLUS, ac
    ld   LINK_LO, x             ; CALL fs_getb
    ld   fsw_r78, [x]
    ld   LINK_HI, x
    ld   fsw_r78 >> 8, [x]
    ld   fs_getb >> 8, y
    jmp  fs_getb
fsw_r78:
    ld   [T4], ac
    or   [T5], ac
    or   [T6], ac
    or   [T7], ac
    bne  fw_link
    ld   V_WCLUS, ac            ; the file's first cluster
    ld   LINK_LO, x             ; CALL fs_put
    ld   fsw_r79, [x]
    ld   LINK_HI, x
    ld   fsw_r79 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fsw_r79:
    bra  fw_setl
fw_link:
    ld   V_WLAST, ac            ; after the last one: FAT[last] = new
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r80, [x]
    ld   LINK_HI, x
    ld   fsw_r80 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r80:
    ld   LINK_LO, x             ; CALL fw_entry
    ld   fsw_r81, [x]
    ld   LINK_HI, x
    ld   fsw_r81 >> 8, [x]
    ld   fw_entry >> 8, y
    jmp  fw_entry
fsw_r81:
    bne  fw_ret
    ld   V_WSECT, ac
    ld   LINK_LO, x             ; CALL fs_getb
    ld   fsw_r82, [x]
    ld   LINK_HI, x
    ld   fsw_r82 >> 8, [x]
    ld   fs_getb >> 8, y
    jmp  fs_getb
fsw_r82:
    ld   LINK_LO, x             ; CALL fw_fatset
    ld   fsw_r83, [x]
    ld   LINK_HI, x
    ld   fsw_r83 >> 8, [x]
    ld   fw_fatset >> 8, y
    jmp  fw_fatset
fsw_r83:
    ld   V_WSECT, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r84, [x]
    ld   LINK_HI, x
    ld   fsw_r84 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r84:
fw_setl:
    ld   V_WLAST, ac
    ld   LINK_LO, x             ; CALL fs_put
    ld   fsw_r85, [x]
    ld   LINK_HI, x
    ld   fsw_r85 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fsw_r85:
    ld   LINK_LO, x             ; CALL fw_flush
    ld   fsw_r86, [x]
    ld   LINK_HI, x
    ld   fsw_r86 >> 8, [x]
    ld   fw_flush >> 8, y
    jmp  fw_flush
fsw_r86:
    bne  fw_ret
    ld   V_WLAST, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r87, [x]
    ld   LINK_HI, x
    ld   fsw_r87 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r87:
    ld   LINK_LO, x             ; CALL fs_clba
    ld   fsw_r88, [x]
    ld   LINK_HI, x
    ld   fsw_r88 >> 8, [x]
    ld   fs_clba >> 8, y
    jmp  fs_clba
fsw_r88:
    ld   V_WSECT, ac
    ld   LINK_LO, x             ; CALL fs_put
    ld   fsw_r89, [x]
    ld   LINK_HI, x
    ld   fsw_r89 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fsw_r89:
    ld   FSV, y
    ld   V_SPC, x
    ld   [y,x], ac
    ld   V_WSLEFT, x
    ld   ac, [y,x]
    ld   fw_sec2 >> 8, y
    jmp  fw_sec2
fw_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave


#addr 0xBD00
fs_close:
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
    ld   FSV, y
    ld   V_WENT, x
    ld   [y,x], ac
    blt  fcl_open
    ld   E_NOFILE, ac
    ld   lib_leave >> 8, y
    jmp  lib_leave
fcl_open:
    and  0x0F, ac
    ld   ac, [y,x]              ; closed, whatever happens next
    ld   [R0], ac               ; the size, kept in V_UBUF-V_LBUF
    ld   ac, [T0]
    ld   [R1], ac
    ld   ac, [T1]
    ld   [R2], ac
    ld   ac, [T2]
    ld   [R3], ac
    ld   ac, [T3]
    ld   V_UBUF, ac
    ld   LINK_LO, x             ; CALL fs_put
    ld   fsw_r95, [x]
    ld   LINK_HI, x
    ld   fsw_r95 >> 8, [x]
    ld   fs_put >> 8, y
    jmp  fs_put
fsw_r95:
    ld   LINK_LO, x             ; CALL fw_flush
    ld   fsw_r96, [x]
    ld   LINK_HI, x
    ld   fsw_r96 >> 8, [x]
    ld   fw_flush >> 8, y
    jmp  fw_flush
fsw_r96:
    bne  fcl_ret
    ld   V_WESEC, ac            ; the entry's sector
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r97, [x]
    ld   LINK_HI, x
    ld   fsw_r97 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r97:
    ld   LINK_LO, x             ; CALL fw_lba
    ld   fsw_r98, [x]
    ld   LINK_HI, x
    ld   fsw_r98 >> 8, [x]
    ld   fw_lba >> 8, y
    jmp  fw_lba
fsw_r98:
    ld   LINK_LO, x             ; CALL sd_read
    ld   fsw_r99, [x]
    ld   LINK_HI, x
    ld   fsw_r99 >> 8, [x]
    ld   sd_read >> 8, y
    jmp  sd_read
fsw_r99:
    bne  fcl_ret
    ld   FSV, y
    ld   V_FATC + 3, x          ; FS_BUF holds the folder sector
    ld   0xFF, [y,x]
    ld   V_WENT, x
    ld   [y,x], ac
    ld   LINK_LO, x             ; CALL fw_ebase
    ld   fsw_r100, [x]
    ld   LINK_HI, x
    ld   fsw_r100 >> 8, [x]
    ld   fw_ebase >> 8, y
    jmp  fw_ebase
fsw_r100:
    ld   fcl_fill >> 8, y
    jmp  fcl_fill
fcl_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave


#addr 0xBE00
fcl_fill:
    ld   V_WCLUS, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r101, [x]
    ld   LINK_HI, x
    ld   fsw_r101 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r101:
    ld   [IO_T0], ac
    add  26, x
    ld   [IO_T1], y
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [IO_T0], ac
    add  27, x
    ld   [T1], ac
    ld   ac, [y,x]
    ld   [IO_T0], ac
    add  20, x
    ld   [T2], ac
    ld   ac, [y,x]
    ld   [IO_T0], ac
    add  21, x
    ld   [T3], ac
    ld   ac, [y,x]
    ld   V_UBUF, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r102, [x]
    ld   LINK_HI, x
    ld   fsw_r102 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r102:
    ld   [IO_T0], ac
    add  28, x
    ld   [IO_T1], y
    ld   [T0], ac
    ld   ac, [y,x]
    ld   [IO_T0], ac
    add  29, x
    ld   [T1], ac
    ld   ac, [y,x]
    ld   [IO_T0], ac
    add  30, x
    ld   [T2], ac
    ld   ac, [y,x]
    ld   [IO_T0], ac
    add  31, x
    ld   [T3], ac
    ld   ac, [y,x]
    ld   V_WESEC, ac
    ld   LINK_LO, x             ; CALL fs_get
    ld   fsw_r103, [x]
    ld   LINK_HI, x
    ld   fsw_r103 >> 8, [x]
    ld   fs_get >> 8, y
    jmp  fs_get
fsw_r103:
    ld   LINK_LO, x             ; CALL fw_lba
    ld   fsw_r104, [x]
    ld   LINK_HI, x
    ld   fsw_r104 >> 8, [x]
    ld   fw_lba >> 8, y
    jmp  fw_lba
fsw_r104:
    ld   LINK_LO, x             ; CALL sd_write
    ld   fsw_r105, [x]
    ld   LINK_HI, x
    ld   fsw_r105 >> 8, [x]
    ld   sd_write >> 8, y
    jmp  sd_write
fsw_r105:
    ld   lib_leave >> 8, y
    jmp  lib_leave

; ============================================================
; fs_save - write a block of memory as a file in the current folder
;   in:      R1:R0 = the name, R5:R4 = the first byte, R3:R2 = the length
;            (1-65535; whole 512-byte sectors are read from memory, so up
;            to 511 bytes past the end are read too)
;   out:     AC = 0, or an error as fs_create, fs_write, fs_close; when a
;            write fails (the card is full, 14) the file is left empty
;   changes: R0-R5, X, Y, T0-T7, IO_T0-IO_T3, IO_TMP
;   clocks:  about 130,000 per 512 bytes plus the card's busy time
; ============================================================

#addr 0xBF00
fs_save:
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
    ld   FSV, y
    ld   V_WBUF, x              ; the length, while fs_create works
    ld   [R2], ac               ; (that changes R0-R5 and V_UBUF)
    ld   ac, [y,x]
    ld   V_WBUF + 1, x
    ld   [R3], ac
    ld   ac, [y,x]
    ld   V_WSAVE, x             ; and the address
    ld   [R4], ac
    ld   ac, [y,x]
    ld   V_WSAVE + 1, x
    ld   [R5], ac
    ld   ac, [y,x]
    ld   LINK_LO, x             ; CALL fs_create
    ld   fsw_r106, [x]
    ld   LINK_HI, x
    ld   fsw_r106 >> 8, [x]
    ld   fs_create >> 8, y
    jmp  fs_create
fsw_r106:
    bne  fsv_ret
    ld   FSV, y
    ld   V_WSAVE, x
    ld   [y,x], ac
    ld   ac, [R4]
    ld   V_WSAVE + 1, x
    ld   [y,x], ac
    ld   ac, [R5]
    ld   V_WBUF, x              ; the size
    ld   [y,x], ac
    ld   V_UBUF, x
    ld   ac, [y,x]
    ld   V_LBUF, x              ; and the bytes left to write
    ld   ac, [y,x]
    ld   V_WBUF + 1, x
    ld   [y,x], ac
    ld   V_UBUF + 1, x
    ld   ac, [y,x]
    ld   V_LBUF + 1, x
    ld   ac, [y,x]
fsv_loop:
    ld   FSV, y
    ld   V_LBUF, x
    ld   [y,x], ac
    ld   V_LBUF + 1, x
    or   [y,x], ac
    beq  fsv_close
    ld   LINK_LO, x             ; CALL fs_write
    ld   fsw_r107, [x]
    ld   LINK_HI, x
    ld   fsw_r107 >> 8, [x]
    ld   fs_write >> 8, y
    jmp  fs_write
fsw_r107:
    bne  fsv_bad
    ld   FSV, y
    ld   V_LBUF + 1, x
    ld   [y,x], ac
    sub  2, ac                  ; 512 fewer
    bcs  fsv_zero
    ld   ac, [y,x]
    bra  fsv_loop
fsv_zero:
    ld   0, [y,x]               ; less than 512 were left
    ld   V_LBUF, x
    ld   0, [y,x]
    bra  fsv_loop
fsv_close:
    ld   V_UBUF, x
    ld   [y,x], ac
    ld   ac, [R0]
    ld   V_UBUF + 1, x
    ld   [y,x], ac
    ld   ac, [R1]
    clr  ac
    ld   ac, [R2]
    ld   ac, [R3]
    ld   LINK_LO, x             ; CALL fs_close
    ld   fsw_r108, [x]
    ld   LINK_HI, x
    ld   fsw_r108 >> 8, [x]
    ld   fs_close >> 8, y
    jmp  fs_close
fsw_r108:
fsv_ret:
    ld   lib_leave >> 8, y
    jmp  lib_leave
fsv_bad:
    ld   fsv_abort >> 8, y
    jmp  fsv_abort

