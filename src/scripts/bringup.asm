; bringup.asm - the bring-up test ROM (docs/BRINGUP.md)
;
; Written by gen_bringup.py; edit that, not this file.  A complete 64 KB
; ROM image with its own reset code: burn x0000-x7FFF into the lower ROM
; chip (#33) and x8000-xFFFF into the upper one (#34)
; (test_bringup_sim.py --bin writes bringup_lo.bin and bringup_hi.bin).
;
; Fail loops: test N stops at x0080 + 4N (PC high = 00, PC low Q7 = 1,
; Q6:Q2 = N).  Tests:
;   1 branches  2 AND  3 OR  4 XOR  5 ADD  6 SUB  7 carry  8 SHR
;   9 AC/X  10 Y address  11 X address  12 ROM data  13 RAM data
;   14 map register  15 RAM address lines  16 video line read
;
; Date: 10/19/2026

#include "placard.asm"
#include "placard_lib.asm"

T15A     = 0x30
T15B     = 0x31
T15C     = 0x32
LR_AND   = 0x33
LR_OR    = 0x34
LR_TMP   = 0x35
LR_CL    = 0x36
LR_CH    = 0x37
LASTF    = 0x40
LOOP_LO  = 0x41
LOOP_HI  = 0x42
RT_IDX   = 0x43
RT_PAGE  = 0x44
RT_GOT   = 0x45
RT_EXP   = 0x46
RT_PL    = 0x47
RT_PH    = 0x48
RT_EL    = 0x49
RT_EH    = 0x4A
RT_BADH  = 0x4B
RT_BADL  = 0x4C
RT_BADE  = 0x4D
RT_BADG  = 0x4E
ECHO     = 0x4F
TONE     = 0x50
SD_R     = 0x51
FS_R     = 0x52
M_INIT   = 0x53
MX_LO    = 0x54
MX_HI    = 0x55
MY_LO    = 0x56
MY_HI    = 0x57
B_C      = 0x58
B_Y      = 0x59
B_V      = 0x5A
LINEV    = 0x5B
KEYV     = 0x5C

; reset (the CPU starts at x0000 with the map all ROM)
#addr 0x0000
    ld   start >> 8, y
    jmp  start

; fail loops: test N stops here at x0080 + 4N
#addr 0x0084
#addr 0x0084
fail1:
    bra  fail1
#addr 0x0088
fail2:
    bra  fail2
#addr 0x008C
fail3:
    bra  fail3
#addr 0x0090
fail4:
    bra  fail4
#addr 0x0094
fail5:
    bra  fail5
#addr 0x0098
fail6:
    bra  fail6
#addr 0x009C
fail7:
    bra  fail7
#addr 0x00A0
fail8:
    bra  fail8
#addr 0x00A4
fail9:
    bra  fail9
#addr 0x00A8
fail10:
    bra  fail10
#addr 0x00AC
fail11:
    bra  fail11
#addr 0x00B0
fail12:
    bra  fail12
#addr 0x00B4
fail13:
    bra  fail13
#addr 0x00B8
fail14:
    bra  fail14
#addr 0x00BC
fail15:
    bra  fail15
#addr 0x00C0
fail16:
    bra  fail16

; ROM markers for tests 10 and 13 (address -> value)
#addr 0x0100
#addr 0x0110
    #d8 0x01
#addr 0x0210
    #d8 0x02
#addr 0x0410
    #d8 0x04
#addr 0x0810
    #d8 0x08
#addr 0x1010
    #d8 0x10
#addr 0x2010
    #d8 0x20
#addr 0x4010
    #d8 0x40
#addr 0x7E10
    #d8 0x7E
#addr 0x8010
    #d8 0x80
#addr 0xA010
    #d8 0xA0
#addr 0xC010
    #d8 0xC0
#addr 0xFE10
    #d8 0xE7

; test 11: x0F00 + v = v xor 5A
#addr 0x0F00
#addr 0x0F00
    #d8 0x5A
#addr 0x0F01
    #d8 0x5B
#addr 0x0F02
    #d8 0x58
#addr 0x0F04
    #d8 0x5E
#addr 0x0F08
    #d8 0x52
#addr 0x0F10
    #d8 0x4A
#addr 0x0F20
    #d8 0x7A
#addr 0x0F40
    #d8 0x1A
#addr 0x0F80
    #d8 0xDA
#addr 0x0FFF
    #d8 0xA5

; test 12: x3F00 + n = n
#addr 0x3F00
    #d8 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F
    #d8 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F
    #d8 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F
    #d8 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F
    #d8 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F
    #d8 0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F
    #d8 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F
    #d8 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F
    #d8 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F
    #d8 0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F
    #d8 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF
    #d8 0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF
    #d8 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF
    #d8 0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF
    #d8 0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xEB, 0xEC, 0xED, 0xEE, 0xEF
    #d8 0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD, 0xFE, 0xFF

; section 1: the core tests
#addr 0x2100
fail_h:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0x00, y
    jmp  ac
start:
; startup copy: tests 1-16
; ---- core tests (startup) ----
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
; test 1: branches on AC
    ld   0x00, ac
    beq  t1t_2
    bra  t1f_1
t1t_2:
    bne  t1f_1
    blt  t1f_1
    ble  t1t_3
    bra  t1f_1
t1t_3:
    bra  t1ok_4
t1f_1:
    ld   0x84, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t1ok_4:
    ld   0x01, ac
    beq  t1f_5
    bne  t1t_6
    bra  t1f_5
t1t_6:
    blt  t1f_5
    ble  t1f_5
    bra  t1ok_7
t1f_5:
    ld   0x84, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t1ok_7:
    ld   0x10, ac
    beq  t1f_8
    bne  t1t_9
    bra  t1f_8
t1t_9:
    blt  t1f_8
    ble  t1f_8
    bra  t1ok_10
t1f_8:
    ld   0x84, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t1ok_10:
    ld   0x80, ac
    beq  t1f_11
    bne  t1t_12
    bra  t1f_11
t1t_12:
    blt  t1t_13
    bra  t1f_11
t1t_13:
    ble  t1t_14
    bra  t1f_11
t1t_14:
    bra  t1ok_15
t1f_11:
    ld   0x84, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t1ok_15:
    ld   0xFF, ac
    beq  t1f_16
    bne  t1t_17
    bra  t1f_16
t1t_17:
    blt  t1t_18
    bra  t1f_16
t1t_18:
    ble  t1t_19
    bra  t1f_16
t1t_19:
    bra  t1ok_20
t1f_16:
    ld   0x84, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t1ok_20:
    ld   0x7F, ac
    beq  t1f_21
    bne  t1t_22
    bra  t1f_21
t1t_22:
    blt  t1f_21
    ble  t1f_21
    bra  t1ok_23
t1f_21:
    ld   0x84, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t1ok_23:
; test 2: AND
    ld   0xFF, ac
    and  0x0F, ac
    xor  0x0F, ac
    beq  ok_24
    ld   0x88, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_24:
    ld   0xF0, ac
    and  0x3C, ac
    xor  0x30, ac
    beq  ok_25
    ld   0x88, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_25:
    ld   0x55, ac
    and  0xAA, ac
    xor  0x00, ac
    beq  ok_26
    ld   0x88, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_26:
    ld   0xA5, ac
    and  0xFF, ac
    xor  0xA5, ac
    beq  ok_27
    ld   0x88, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_27:
    ld   0x00, ac
    and  0xFF, ac
    xor  0x00, ac
    beq  ok_28
    ld   0x88, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_28:
; test 3: OR
    ld   0x55, ac
    or   0xAA, ac
    xor  0xFF, ac
    beq  ok_29
    ld   0x8C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_29:
    ld   0x0F, ac
    or   0xF0, ac
    xor  0xFF, ac
    beq  ok_30
    ld   0x8C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_30:
    ld   0x00, ac
    or   0x00, ac
    ld   pg_31 >> 8, y
    jmp  pg_31
#addr 0x2200
pg_31:
    xor  0x00, ac
    beq  ok_32
    ld   0x8C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_32:
    ld   0x12, ac
    or   0x21, ac
    xor  0x33, ac
    beq  ok_33
    ld   0x8C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_33:
    ld   0x80, ac
    or   0x01, ac
    xor  0x81, ac
    beq  ok_34
    ld   0x8C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_34:
; test 4: XOR
    ld   0xFF, ac
    xor  0x0F, ac
    xor  0xF0, ac
    beq  ok_35
    ld   0x90, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_35:
    ld   0x55, ac
    xor  0xFF, ac
    xor  0xAA, ac
    beq  ok_36
    ld   0x90, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_36:
    ld   0xA5, ac
    xor  0xA5, ac
    xor  0x00, ac
    beq  ok_37
    ld   0x90, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_37:
    ld   0x3C, ac
    xor  0x0F, ac
    xor  0x33, ac
    beq  ok_38
    ld   0x90, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_38:
; test 5: ADD
    ld   0x0F, ac
    add  0x01, ac
    xor  0x10, ac
    beq  ok_39
    ld   0x94, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_39:
    ld   0x01, ac
    add  0x0F, ac
    xor  0x10, ac
    beq  ok_40
    ld   0x94, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_40:
    ld   0x7F, ac
    add  0x01, ac
    xor  0x80, ac
    beq  ok_41
    ld   0x94, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_41:
    ld   0xFF, ac
    add  0x01, ac
    xor  0x00, ac
    beq  ok_42
    ld   0x94, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_42:
    ld   0x55, ac
    add  0xAA, ac
    xor  0xFF, ac
    beq  ok_43
    ld   0x94, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_43:
    ld   0x88, ac
    add  0x88, ac
    xor  0x10, ac
    beq  ok_44
    ld   0x94, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_44:
    ld   0x12, ac
    add  0x34, ac
    xor  0x46, ac
    beq  ok_45
    ld   0x94, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_45:
    ld   0xF0, ac
    add  0xF0, ac
    xor  0xE0, ac
    beq  ok_46
    ld   0x94, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_46:
; test 6: SUB
    ld   0x10, ac
    sub  0x01, ac
    xor  0x0F, ac
    beq  ok_47
    ld   0x98, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_47:
    ld   0x00, ac
    sub  0x01, ac
    xor  0xFF, ac
    beq  ok_48
    ld   0x98, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_48:
    ld   0x80, ac
    sub  0x01, ac
    xor  0x7F, ac
    beq  ok_49
    ld   0x98, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_49:
    ld   0x55, ac
    sub  0x55, ac
    ld   pg_50 >> 8, y
    jmp  pg_50
#addr 0x2300
pg_50:
    xor  0x00, ac
    beq  ok_51
    ld   0x98, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_51:
    ld   0x46, ac
    sub  0x34, ac
    xor  0x12, ac
    beq  ok_52
    ld   0x98, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_52:
    ld   0xFF, ac
    sub  0x0F, ac
    xor  0xF0, ac
    beq  ok_53
    ld   0x98, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_53:
    ld   0x01, ac
    sub  0xFF, ac
    xor  0x02, ac
    beq  ok_54
    ld   0x98, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_54:
; test 7: carry flag
    ld 0xFF, ac
    add 0x01, ac
    bcc  t7f_55
    bcs  t7t_57
    bra  t7f_55
t7t_57:
    bra  t7ok_56
t7f_55:
    ld   0x9C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t7ok_56:
    ld 0x7F, ac
    add 0x01, ac
    bcs  t7f_58
    bcc  t7t_60
    bra  t7f_58
t7t_60:
    bra  t7ok_59
t7f_58:
    ld   0x9C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t7ok_59:
    ld 0x00, ac
    sub 0x01, ac
    bcc  t7f_61
    bcs  t7t_63
    bra  t7f_61
t7t_63:
    bra  t7ok_62
t7f_61:
    ld   0x9C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t7ok_62:
    ld 0x10, ac
    sub 0x01, ac
    bcs  t7f_64
    bcc  t7t_66
    bra  t7f_64
t7t_66:
    bra  t7ok_65
t7f_64:
    ld   0x9C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t7ok_65:
    ld 0x80, ac
    shl ac
    bcc  t7f_67
    bcs  t7t_69
    bra  t7f_67
t7t_69:
    bra  t7ok_68
t7f_67:
    ld   0x9C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t7ok_68:
    ld 0x40, ac
    shl ac
    bcs  t7f_70
    bcc  t7t_72
    bra  t7f_70
t7t_72:
    bra  t7ok_71
t7f_70:
    ld   0x9C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t7ok_71:
    ld 0xFF, ac
    add 0x01, ac
    ld 0x00, ac
    ld ac, x
    bcc  t7f_73
    bcs  t7t_75
    bra  t7f_73
t7t_75:
    bra  t7ok_74
t7f_73:
    ld   0x9C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t7ok_74:
; test 8: SHR
    ld   0x80, ac
    shr  ac
    xor  0x40, ac
    beq  ok_76
    ld   0xA0, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_76:
    ld   0x01, ac
    shr  ac
    xor  0x00, ac
    beq  ok_77
    ld   0xA0, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_77:
    ld   0x10, ac
    shr  ac
    xor  0x08, ac
    beq  ok_78
    ld   0xA0, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_78:
    ld   0xFE, ac
    shr  ac
    xor  0x7F, ac
    beq  ok_79
    ld   0xA0, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_79:
    ld   0xAA, ac
    shr  ac
    xor  0x55, ac
    beq  ok_80
    ld   0xA0, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_80:
    ld   0x55, ac
    shr  ac
    ld   pg_81 >> 8, y
    jmp  pg_81
#addr 0x2400
pg_81:
    xor  0x2A, ac
    beq  ok_82
    ld   0xA0, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_82:
; test 9: X register (AC -> X -> AC)
    ld   0x00, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x00, ac
    beq  ok_83
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_83:
    ld   0xFF, x
    ld   x, ac
    xor  0xFF, ac
    beq  ok_84
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_84:
    ld   0xFF, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0xFF, ac
    beq  ok_85
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_85:
    ld   0x00, x
    ld   x, ac
    xor  0x00, ac
    beq  ok_86
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_86:
    ld   0x55, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x55, ac
    beq  ok_87
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_87:
    ld   0xAA, x
    ld   x, ac
    xor  0xAA, ac
    beq  ok_88
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_88:
    ld   0xAA, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0xAA, ac
    beq  ok_89
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_89:
    ld   0x55, x
    ld   x, ac
    xor  0x55, ac
    beq  ok_90
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_90:
    ld   0x01, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x01, ac
    beq  ok_91
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_91:
    ld   0xFE, x
    ld   x, ac
    xor  0xFE, ac
    beq  ok_92
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_92:
    ld   0x02, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x02, ac
    beq  ok_93
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_93:
    ld   0xFD, x
    ld   x, ac
    xor  0xFD, ac
    beq  ok_94
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_94:
    ld   0x04, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x04, ac
    beq  ok_95
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_95:
    ld   0xFB, x
    ld   x, ac
    xor  0xFB, ac
    beq  ok_96
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_96:
    ld   0x08, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x08, ac
    beq  ok_97
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_97:
    ld   0xF7, x
    ld   x, ac
    xor  0xF7, ac
    beq  ok_98
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_98:
    ld   0x10, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    ld   pg_99 >> 8, y
    jmp  pg_99
#addr 0x2500
pg_99:
    xor  0x10, ac
    beq  ok_100
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_100:
    ld   0xEF, x
    ld   x, ac
    xor  0xEF, ac
    beq  ok_101
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_101:
    ld   0x20, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x20, ac
    beq  ok_102
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_102:
    ld   0xDF, x
    ld   x, ac
    xor  0xDF, ac
    beq  ok_103
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_103:
    ld   0x40, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x40, ac
    beq  ok_104
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_104:
    ld   0xBF, x
    ld   x, ac
    xor  0xBF, ac
    beq  ok_105
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_105:
    ld   0x80, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x80, ac
    beq  ok_106
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_106:
    ld   0x7F, x
    ld   x, ac
    xor  0x7F, ac
    beq  ok_107
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_107:
; test 10: Y register, address bits 15-8
    ld   0x01, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x01, ac
    beq  ok_108
    ld   0xA8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_108:
    ld   0x02, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x02, ac
    beq  ok_109
    ld   0xA8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_109:
    ld   0x04, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x04, ac
    beq  ok_110
    ld   0xA8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_110:
    ld   0x08, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x08, ac
    beq  ok_111
    ld   0xA8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_111:
    ld   0x10, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x10, ac
    beq  ok_112
    ld   0xA8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_112:
    ld   0x20, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x20, ac
    beq  ok_113
    ld   0xA8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_113:
    ld   0x40, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x40, ac
    beq  ok_114
    ld   0xA8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_114:
    ld   0x80, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x80, ac
    beq  ok_115
    ld   0xA8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_115:
; test 11: X register, address bits 7-0
    ld   0x0F, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0x5A, ac
    beq  ok_116
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_116:
    ld   0x0F, y
    ld   0x01, x
    ld   [y,x], ac
    ld   pg_117 >> 8, y
    jmp  pg_117
#addr 0x2600
pg_117:
    xor  0x5B, ac
    beq  ok_118
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_118:
    ld   0x0F, y
    ld   0x02, x
    ld   [y,x], ac
    xor  0x58, ac
    beq  ok_119
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_119:
    ld   0x0F, y
    ld   0x04, x
    ld   [y,x], ac
    xor  0x5E, ac
    beq  ok_120
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_120:
    ld   0x0F, y
    ld   0x08, x
    ld   [y,x], ac
    xor  0x52, ac
    beq  ok_121
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_121:
    ld   0x0F, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x4A, ac
    beq  ok_122
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_122:
    ld   0x0F, y
    ld   0x20, x
    ld   [y,x], ac
    xor  0x7A, ac
    beq  ok_123
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_123:
    ld   0x0F, y
    ld   0x40, x
    ld   [y,x], ac
    xor  0x1A, ac
    beq  ok_124
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_124:
    ld   0x0F, y
    ld   0x80, x
    ld   [y,x], ac
    xor  0xDA, ac
    beq  ok_125
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_125:
    ld   0x0F, y
    ld   0xFF, x
    ld   [y,x], ac
    xor  0xA5, ac
    beq  ok_126
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_126:
; test 12: ROM data, table at x3F00
    ld   0x3F, y
    ld   0x00, x
t12_127:
    ld   [y,x], ac
    xor  x, ac
    bne  t12f_128
    ld   x, ac
    inc
    ld   ac, x
    bne  t12_127
    bra  t12ok_129
t12f_128:
    ld   0xB0, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t12ok_129:
; test 13: RAM data lines
    ld   0x50, y
    ld   0x00, x
    ld   0x11, [y,x]
    ld   0x00, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    xor  0x00, ac
    beq  ok_130
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_130:
    ld   0x31, x
    ld   0xFF, [x]
    ld   [x], ac
    xor  0xFF, ac
    beq  ok_131
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_131:
    ld   0x00, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x00, ac
    beq  ok_132
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_132:
    ld   0x90, y
    ld   0x10, x
    ld   0x00, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x00, ac
    beq  ok_133
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_133:
    ld   0xFF, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xFF, ac
    beq  ok_134
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_134:
    ld   0xFF, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    ld   pg_135 >> 8, y
    jmp  pg_135
#addr 0x2700
pg_135:
    xor  0xFF, ac
    beq  ok_136
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_136:
    ld   0x31, x
    ld   0x00, [x]
    ld   [x], ac
    xor  0x00, ac
    beq  ok_137
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_137:
    ld   0xFF, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0xFF, ac
    beq  ok_138
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_138:
    ld   0x90, y
    ld   0x10, x
    ld   0xFF, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xFF, ac
    beq  ok_139
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_139:
    ld   0x00, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x00, ac
    beq  ok_140
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_140:
    ld   0x55, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    xor  0x55, ac
    beq  ok_141
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_141:
    ld   0x31, x
    ld   0xAA, [x]
    ld   [x], ac
    xor  0xAA, ac
    beq  ok_142
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_142:
    ld   0x55, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x55, ac
    beq  ok_143
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_143:
    ld   0x90, y
    ld   0x10, x
    ld   0x55, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x55, ac
    beq  ok_144
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_144:
    ld   0xAA, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xAA, ac
    beq  ok_145
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_145:
    ld   0xAA, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    xor  0xAA, ac
    beq  ok_146
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_146:
    ld   0x31, x
    ld   0x55, [x]
    ld   [x], ac
    xor  0x55, ac
    beq  ok_147
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_147:
    ld   0xAA, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0xAA, ac
    beq  ok_148
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_148:
    ld   0x90, y
    ld   0x10, x
    ld   0xAA, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xAA, ac
    beq  ok_149
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_149:
    ld   0x55, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x55, ac
    beq  ok_150
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_150:
    ld   0x01, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    ld   pg_151 >> 8, y
    jmp  pg_151
#addr 0x2800
pg_151:
    xor  0x01, ac
    beq  ok_152
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_152:
    ld   0x31, x
    ld   0xFE, [x]
    ld   [x], ac
    xor  0xFE, ac
    beq  ok_153
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_153:
    ld   0x01, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x01, ac
    beq  ok_154
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_154:
    ld   0x90, y
    ld   0x10, x
    ld   0x01, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x01, ac
    beq  ok_155
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_155:
    ld   0xFE, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xFE, ac
    beq  ok_156
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_156:
    ld   0x02, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    xor  0x02, ac
    beq  ok_157
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_157:
    ld   0x31, x
    ld   0xFD, [x]
    ld   [x], ac
    xor  0xFD, ac
    beq  ok_158
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_158:
    ld   0x02, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x02, ac
    beq  ok_159
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_159:
    ld   0x90, y
    ld   0x10, x
    ld   0x02, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x02, ac
    beq  ok_160
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_160:
    ld   0xFD, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xFD, ac
    beq  ok_161
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_161:
    ld   0x04, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    xor  0x04, ac
    beq  ok_162
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_162:
    ld   0x31, x
    ld   0xFB, [x]
    ld   [x], ac
    xor  0xFB, ac
    beq  ok_163
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_163:
    ld   0x04, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x04, ac
    beq  ok_164
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_164:
    ld   0x90, y
    ld   0x10, x
    ld   0x04, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x04, ac
    beq  ok_165
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_165:
    ld   0xFB, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xFB, ac
    beq  ok_166
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_166:
    ld   0x08, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    ld   pg_167 >> 8, y
    jmp  pg_167
#addr 0x2900
pg_167:
    xor  0x08, ac
    beq  ok_168
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_168:
    ld   0x31, x
    ld   0xF7, [x]
    ld   [x], ac
    xor  0xF7, ac
    beq  ok_169
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_169:
    ld   0x08, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x08, ac
    beq  ok_170
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_170:
    ld   0x90, y
    ld   0x10, x
    ld   0x08, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x08, ac
    beq  ok_171
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_171:
    ld   0xF7, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xF7, ac
    beq  ok_172
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_172:
    ld   0x10, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    xor  0x10, ac
    beq  ok_173
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_173:
    ld   0x31, x
    ld   0xEF, [x]
    ld   [x], ac
    xor  0xEF, ac
    beq  ok_174
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_174:
    ld   0x10, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x10, ac
    beq  ok_175
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_175:
    ld   0x90, y
    ld   0x10, x
    ld   0x10, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x10, ac
    beq  ok_176
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_176:
    ld   0xEF, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xEF, ac
    beq  ok_177
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_177:
    ld   0x20, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    xor  0x20, ac
    beq  ok_178
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_178:
    ld   0x31, x
    ld   0xDF, [x]
    ld   [x], ac
    xor  0xDF, ac
    beq  ok_179
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_179:
    ld   0x20, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x20, ac
    beq  ok_180
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_180:
    ld   0x90, y
    ld   0x10, x
    ld   0x20, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x20, ac
    beq  ok_181
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_181:
    ld   0xDF, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xDF, ac
    beq  ok_182
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_182:
    ld   0x40, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    ld   pg_183 >> 8, y
    jmp  pg_183
#addr 0x2A00
pg_183:
    xor  0x40, ac
    beq  ok_184
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_184:
    ld   0x31, x
    ld   0xBF, [x]
    ld   [x], ac
    xor  0xBF, ac
    beq  ok_185
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_185:
    ld   0x40, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x40, ac
    beq  ok_186
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_186:
    ld   0x90, y
    ld   0x10, x
    ld   0x40, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x40, ac
    beq  ok_187
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_187:
    ld   0xBF, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xBF, ac
    beq  ok_188
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_188:
    ld   0x80, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    xor  0x80, ac
    beq  ok_189
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_189:
    ld   0x31, x
    ld   0x7F, [x]
    ld   [x], ac
    xor  0x7F, ac
    beq  ok_190
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_190:
    ld   0x80, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x80, ac
    beq  ok_191
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_191:
    ld   0x90, y
    ld   0x10, x
    ld   0x80, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x80, ac
    beq  ok_192
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_192:
    ld   0x7F, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x7F, ac
    beq  ok_193
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_193:
; test 14: ROM/RAM map register
    ld   0x01, y
    ld   0x10, x
    ld   0xFE, [y,x]
    ld   0x50, y
    ld   0x00, x
    ld   0x01, [y,x]
    ld   0x01, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0xFE, ac
    beq  ok_194
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_194:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0x01, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x01, ac
    beq  ok_195
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_195:
    ld   map_s1_a >> 8, y
    jmp  map_s1_a
t13b_196:
    ld   0x40, y
    ld   0x10, x
    ld   0xBF, [y,x]
    ld   0x50, y
    ld   0x00, x
    ld   0x04, [y,x]
    ld   0x40, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0xBF, ac
    beq  ok_197
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_197:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0x40, y
    ld   0x10, x
    ld   [y,x], ac
    ld   pg_198 >> 8, y
    jmp  pg_198
#addr 0x2B00
pg_198:
    xor  0x40, ac
    beq  ok_199
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_199:
    ld   0x7E, y
    ld   0x10, x
    ld   0x81, [y,x]
    ld   0x50, y
    ld   0x00, x
    ld   0x08, [y,x]
    ld   0x7E, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x81, ac
    beq  ok_200
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_200:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0x7E, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x7E, ac
    beq  ok_201
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_201:
    ld   0x80, y
    ld   0x10, x
    ld   0x7F, [y,x]
    ld   0x50, y
    ld   0x00, x
    ld   0x10, [y,x]
    ld   0x80, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x7F, ac
    beq  ok_202
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_202:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0x80, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x80, ac
    beq  ok_203
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_203:
    ld   0xA0, y
    ld   0x10, x
    ld   0x5F, [y,x]
    ld   0x50, y
    ld   0x00, x
    ld   0x20, [y,x]
    ld   0xA0, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x5F, ac
    beq  ok_204
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_204:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0xA0, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0xA0, ac
    beq  ok_205
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_205:
    ld   0xC0, y
    ld   0x10, x
    ld   0x3F, [y,x]
    ld   0x50, y
    ld   0x00, x
    ld   0x40, [y,x]
    ld   0xC0, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x3F, ac
    beq  ok_206
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_206:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0xC0, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0xC0, ac
    beq  ok_207
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_207:
    ld   0xFE, y
    ld   0x10, x
    ld   0x18, [y,x]
    ld   0x50, y
    ld   0x00, x
    ld   0x80, [y,x]
    ld   0xFE, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x18, ac
    beq  ok_208
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_208:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0xFE, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0xE7, ac
    beq  ok_209
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_209:
    ld   pg_211 >> 8, y
    jmp  pg_211
#addr 0x2C00
pg_211:
    ld   ram_addr_test >> 8, y
    jmp  ram_addr_test
t14b_210:
; test 16: video line read, AND and OR of about 1.5 frames of reads
    ld   0x50, y
    ld   0x00, x
    ld   0x01, [y,x]
    ld   0xFF, ac
    ld   ac, [0x33]
    ld   0x00, ac
    ld   ac, [0x34]
    ld   0x00, ac
    ld   ac, [0x36]
    ld   0x40, ac
    ld   ac, [0x37]
    ld   0x50, y
    ld   0x00, x
t16_212:
    ld   [y,x], ac
    ld   ac, [0x35]
    and  [0x33], ac
    ld   ac, [0x33]
    ld   [0x35], ac
    or   [0x34], ac
    ld   ac, [0x34]
    ld   [0x36], ac
    dec
    ld   ac, [0x36]
    bne  t16_212
    ld   [0x37], ac
    dec
    ld   ac, [0x37]
    bne  t16_212
    ld   [0x33], ac
    xor  0x00, ac
    beq  ok_213
    ld   0xC0, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_213:
    ld   [0x34], ac
    xor  0xFF, ac
    beq  ok_214
    ld   0xC0, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_214:
    ld   main >> 8, y
    jmp  main
core_loop:
; frame loop copy: tests 1-14
; ---- core tests (loop) ----
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
; test 1: branches on AC
    ld   0x00, ac
    beq  t1t_216
    bra  t1f_215
t1t_216:
    bne  t1f_215
    blt  t1f_215
    ble  t1t_217
    bra  t1f_215
t1t_217:
    bra  t1ok_218
t1f_215:
    ld   0x84, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t1ok_218:
    ld   0x01, ac
    beq  t1f_219
    bne  t1t_220
    bra  t1f_219
t1t_220:
    blt  t1f_219
    ble  t1f_219
    bra  t1ok_221
t1f_219:
    ld   0x84, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t1ok_221:
    ld   0x10, ac
    beq  t1f_222
    bne  t1t_223
    bra  t1f_222
t1t_223:
    blt  t1f_222
    ble  t1f_222
    bra  t1ok_224
t1f_222:
    ld   0x84, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t1ok_224:
    ld   0x80, ac
    beq  t1f_225
    bne  t1t_226
    bra  t1f_225
t1t_226:
    blt  t1t_227
    bra  t1f_225
t1t_227:
    ble  t1t_228
    bra  t1f_225
t1t_228:
    bra  t1ok_229
t1f_225:
    ld   0x84, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t1ok_229:
    ld   0xFF, ac
    beq  t1f_230
    bne  t1t_231
    bra  t1f_230
t1t_231:
    blt  t1t_232
    bra  t1f_230
t1t_232:
    ble  t1t_233
    bra  t1f_230
t1t_233:
    bra  t1ok_234
t1f_230:
    ld   0x84, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t1ok_234:
    ld   pg_235 >> 8, y
    jmp  pg_235
#addr 0x2D00
pg_235:
    ld   0x7F, ac
    beq  t1f_236
    bne  t1t_237
    bra  t1f_236
t1t_237:
    blt  t1f_236
    ble  t1f_236
    bra  t1ok_238
t1f_236:
    ld   0x84, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t1ok_238:
; test 2: AND
    ld   0xFF, ac
    and  0x0F, ac
    xor  0x0F, ac
    beq  ok_239
    ld   0x88, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_239:
    ld   0xF0, ac
    and  0x3C, ac
    xor  0x30, ac
    beq  ok_240
    ld   0x88, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_240:
    ld   0x55, ac
    and  0xAA, ac
    xor  0x00, ac
    beq  ok_241
    ld   0x88, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_241:
    ld   0xA5, ac
    and  0xFF, ac
    xor  0xA5, ac
    beq  ok_242
    ld   0x88, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_242:
    ld   0x00, ac
    and  0xFF, ac
    xor  0x00, ac
    beq  ok_243
    ld   0x88, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_243:
; test 3: OR
    ld   0x55, ac
    or   0xAA, ac
    xor  0xFF, ac
    beq  ok_244
    ld   0x8C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_244:
    ld   0x0F, ac
    or   0xF0, ac
    xor  0xFF, ac
    beq  ok_245
    ld   0x8C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_245:
    ld   0x00, ac
    or   0x00, ac
    xor  0x00, ac
    beq  ok_246
    ld   0x8C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_246:
    ld   0x12, ac
    or   0x21, ac
    xor  0x33, ac
    beq  ok_247
    ld   0x8C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_247:
    ld   0x80, ac
    or   0x01, ac
    xor  0x81, ac
    beq  ok_248
    ld   0x8C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_248:
; test 4: XOR
    ld   0xFF, ac
    xor  0x0F, ac
    xor  0xF0, ac
    beq  ok_249
    ld   0x90, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_249:
    ld   0x55, ac
    xor  0xFF, ac
    xor  0xAA, ac
    beq  ok_250
    ld   0x90, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_250:
    ld   0xA5, ac
    xor  0xA5, ac
    xor  0x00, ac
    beq  ok_251
    ld   0x90, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_251:
    ld   0x3C, ac
    xor  0x0F, ac
    xor  0x33, ac
    beq  ok_252
    ld   0x90, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_252:
; test 5: ADD
    ld   0x0F, ac
    add  0x01, ac
    xor  0x10, ac
    beq  ok_253
    ld   0x94, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_253:
    ld   0x01, ac
    add  0x0F, ac
    xor  0x10, ac
    beq  ok_254
    ld   0x94, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_254:
    ld   0x7F, ac
    add  0x01, ac
    ld   pg_255 >> 8, y
    jmp  pg_255
#addr 0x2E00
pg_255:
    xor  0x80, ac
    beq  ok_256
    ld   0x94, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_256:
    ld   0xFF, ac
    add  0x01, ac
    xor  0x00, ac
    beq  ok_257
    ld   0x94, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_257:
    ld   0x55, ac
    add  0xAA, ac
    xor  0xFF, ac
    beq  ok_258
    ld   0x94, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_258:
    ld   0x88, ac
    add  0x88, ac
    xor  0x10, ac
    beq  ok_259
    ld   0x94, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_259:
    ld   0x12, ac
    add  0x34, ac
    xor  0x46, ac
    beq  ok_260
    ld   0x94, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_260:
    ld   0xF0, ac
    add  0xF0, ac
    xor  0xE0, ac
    beq  ok_261
    ld   0x94, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_261:
; test 6: SUB
    ld   0x10, ac
    sub  0x01, ac
    xor  0x0F, ac
    beq  ok_262
    ld   0x98, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_262:
    ld   0x00, ac
    sub  0x01, ac
    xor  0xFF, ac
    beq  ok_263
    ld   0x98, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_263:
    ld   0x80, ac
    sub  0x01, ac
    xor  0x7F, ac
    beq  ok_264
    ld   0x98, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_264:
    ld   0x55, ac
    sub  0x55, ac
    xor  0x00, ac
    beq  ok_265
    ld   0x98, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_265:
    ld   0x46, ac
    sub  0x34, ac
    xor  0x12, ac
    beq  ok_266
    ld   0x98, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_266:
    ld   0xFF, ac
    sub  0x0F, ac
    xor  0xF0, ac
    beq  ok_267
    ld   0x98, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_267:
    ld   0x01, ac
    sub  0xFF, ac
    xor  0x02, ac
    beq  ok_268
    ld   0x98, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_268:
; test 7: carry flag
    ld 0xFF, ac
    add 0x01, ac
    bcc  t7f_269
    bcs  t7t_271
    bra  t7f_269
t7t_271:
    bra  t7ok_270
t7f_269:
    ld   0x9C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t7ok_270:
    ld 0x7F, ac
    add 0x01, ac
    bcs  t7f_272
    bcc  t7t_274
    bra  t7f_272
t7t_274:
    bra  t7ok_273
t7f_272:
    ld   0x9C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t7ok_273:
    ld   pg_275 >> 8, y
    jmp  pg_275
#addr 0x2F00
pg_275:
    ld 0x00, ac
    sub 0x01, ac
    bcc  t7f_276
    bcs  t7t_278
    bra  t7f_276
t7t_278:
    bra  t7ok_277
t7f_276:
    ld   0x9C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t7ok_277:
    ld 0x10, ac
    sub 0x01, ac
    bcs  t7f_279
    bcc  t7t_281
    bra  t7f_279
t7t_281:
    bra  t7ok_280
t7f_279:
    ld   0x9C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t7ok_280:
    ld 0x80, ac
    shl ac
    bcc  t7f_282
    bcs  t7t_284
    bra  t7f_282
t7t_284:
    bra  t7ok_283
t7f_282:
    ld   0x9C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t7ok_283:
    ld 0x40, ac
    shl ac
    bcs  t7f_285
    bcc  t7t_287
    bra  t7f_285
t7t_287:
    bra  t7ok_286
t7f_285:
    ld   0x9C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t7ok_286:
    ld 0xFF, ac
    add 0x01, ac
    ld 0x00, ac
    ld ac, x
    bcc  t7f_288
    bcs  t7t_290
    bra  t7f_288
t7t_290:
    bra  t7ok_289
t7f_288:
    ld   0x9C, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t7ok_289:
; test 8: SHR
    ld   0x80, ac
    shr  ac
    xor  0x40, ac
    beq  ok_291
    ld   0xA0, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_291:
    ld   0x01, ac
    shr  ac
    xor  0x00, ac
    beq  ok_292
    ld   0xA0, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_292:
    ld   0x10, ac
    shr  ac
    xor  0x08, ac
    beq  ok_293
    ld   0xA0, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_293:
    ld   0xFE, ac
    shr  ac
    xor  0x7F, ac
    beq  ok_294
    ld   0xA0, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_294:
    ld   0xAA, ac
    shr  ac
    xor  0x55, ac
    beq  ok_295
    ld   0xA0, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_295:
    ld   0x55, ac
    shr  ac
    xor  0x2A, ac
    beq  ok_296
    ld   0xA0, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_296:
; test 9: X register (AC -> X -> AC)
    ld   0x00, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x00, ac
    beq  ok_297
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_297:
    ld   0xFF, x
    ld   x, ac
    xor  0xFF, ac
    beq  ok_298
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_298:
    ld   0xFF, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0xFF, ac
    beq  ok_299
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_299:
    ld   0x00, x
    ld   x, ac
    xor  0x00, ac
    beq  ok_300
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_300:
    ld   0x55, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x55, ac
    beq  ok_301
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_301:
    ld   0xAA, x
    ld   x, ac
    ld   pg_302 >> 8, y
    jmp  pg_302
#addr 0x3000
pg_302:
    xor  0xAA, ac
    beq  ok_303
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_303:
    ld   0xAA, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0xAA, ac
    beq  ok_304
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_304:
    ld   0x55, x
    ld   x, ac
    xor  0x55, ac
    beq  ok_305
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_305:
    ld   0x01, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x01, ac
    beq  ok_306
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_306:
    ld   0xFE, x
    ld   x, ac
    xor  0xFE, ac
    beq  ok_307
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_307:
    ld   0x02, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x02, ac
    beq  ok_308
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_308:
    ld   0xFD, x
    ld   x, ac
    xor  0xFD, ac
    beq  ok_309
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_309:
    ld   0x04, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x04, ac
    beq  ok_310
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_310:
    ld   0xFB, x
    ld   x, ac
    xor  0xFB, ac
    beq  ok_311
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_311:
    ld   0x08, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x08, ac
    beq  ok_312
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_312:
    ld   0xF7, x
    ld   x, ac
    xor  0xF7, ac
    beq  ok_313
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_313:
    ld   0x10, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x10, ac
    beq  ok_314
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_314:
    ld   0xEF, x
    ld   x, ac
    xor  0xEF, ac
    beq  ok_315
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_315:
    ld   0x20, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x20, ac
    beq  ok_316
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_316:
    ld   0xDF, x
    ld   x, ac
    xor  0xDF, ac
    beq  ok_317
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_317:
    ld   0x40, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    xor  0x40, ac
    beq  ok_318
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_318:
    ld   0xBF, x
    ld   x, ac
    xor  0xBF, ac
    beq  ok_319
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_319:
    ld   0x80, ac
    ld   ac, x
    ld   0x00, ac
    ld   x, ac
    ld   pg_320 >> 8, y
    jmp  pg_320
#addr 0x3100
pg_320:
    xor  0x80, ac
    beq  ok_321
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_321:
    ld   0x7F, x
    ld   x, ac
    xor  0x7F, ac
    beq  ok_322
    ld   0xA4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_322:
; test 10: Y register, address bits 15-8
    ld   0x01, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x01, ac
    beq  ok_323
    ld   0xA8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_323:
    ld   0x02, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x02, ac
    beq  ok_324
    ld   0xA8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_324:
    ld   0x04, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x04, ac
    beq  ok_325
    ld   0xA8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_325:
    ld   0x08, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x08, ac
    beq  ok_326
    ld   0xA8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_326:
    ld   0x10, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x10, ac
    beq  ok_327
    ld   0xA8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_327:
    ld   0x20, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x20, ac
    beq  ok_328
    ld   0xA8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_328:
    ld   0x40, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x40, ac
    beq  ok_329
    ld   0xA8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_329:
    ld   0x80, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x80, ac
    beq  ok_330
    ld   0xA8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_330:
; test 11: X register, address bits 7-0
    ld   0x0F, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0x5A, ac
    beq  ok_331
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_331:
    ld   0x0F, y
    ld   0x01, x
    ld   [y,x], ac
    xor  0x5B, ac
    beq  ok_332
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_332:
    ld   0x0F, y
    ld   0x02, x
    ld   [y,x], ac
    xor  0x58, ac
    beq  ok_333
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_333:
    ld   0x0F, y
    ld   0x04, x
    ld   [y,x], ac
    xor  0x5E, ac
    beq  ok_334
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_334:
    ld   0x0F, y
    ld   0x08, x
    ld   [y,x], ac
    xor  0x52, ac
    beq  ok_335
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_335:
    ld   0x0F, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x4A, ac
    beq  ok_336
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_336:
    ld   0x0F, y
    ld   0x20, x
    ld   [y,x], ac
    xor  0x7A, ac
    beq  ok_337
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_337:
    ld   pg_338 >> 8, y
    jmp  pg_338
#addr 0x3200
pg_338:
    ld   0x0F, y
    ld   0x40, x
    ld   [y,x], ac
    xor  0x1A, ac
    beq  ok_339
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_339:
    ld   0x0F, y
    ld   0x80, x
    ld   [y,x], ac
    xor  0xDA, ac
    beq  ok_340
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_340:
    ld   0x0F, y
    ld   0xFF, x
    ld   [y,x], ac
    xor  0xA5, ac
    beq  ok_341
    ld   0xAC, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_341:
; test 12: ROM data, table at x3F00
    ld   0x3F, y
    ld   0x00, x
t12_342:
    ld   [y,x], ac
    xor  x, ac
    bne  t12f_343
    ld   x, ac
    inc
    ld   ac, x
    bne  t12_342
    bra  t12ok_344
t12f_343:
    ld   0xB0, ac
    ld   fail_h >> 8, y
    jmp  fail_h
t12ok_344:
; test 13: RAM data lines
    ld   0x50, y
    ld   0x00, x
    ld   0x11, [y,x]
    ld   0x00, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    xor  0x00, ac
    beq  ok_345
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_345:
    ld   0x31, x
    ld   0xFF, [x]
    ld   [x], ac
    xor  0xFF, ac
    beq  ok_346
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_346:
    ld   0x00, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x00, ac
    beq  ok_347
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_347:
    ld   0x90, y
    ld   0x10, x
    ld   0x00, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x00, ac
    beq  ok_348
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_348:
    ld   0xFF, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xFF, ac
    beq  ok_349
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_349:
    ld   0xFF, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    xor  0xFF, ac
    beq  ok_350
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_350:
    ld   0x31, x
    ld   0x00, [x]
    ld   [x], ac
    xor  0x00, ac
    beq  ok_351
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_351:
    ld   0xFF, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0xFF, ac
    beq  ok_352
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_352:
    ld   0x90, y
    ld   0x10, x
    ld   0xFF, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xFF, ac
    beq  ok_353
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_353:
    ld   0x00, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x00, ac
    beq  ok_354
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_354:
    ld   0x55, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    ld   pg_355 >> 8, y
    jmp  pg_355
#addr 0x3300
pg_355:
    xor  0x55, ac
    beq  ok_356
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_356:
    ld   0x31, x
    ld   0xAA, [x]
    ld   [x], ac
    xor  0xAA, ac
    beq  ok_357
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_357:
    ld   0x55, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x55, ac
    beq  ok_358
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_358:
    ld   0x90, y
    ld   0x10, x
    ld   0x55, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x55, ac
    beq  ok_359
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_359:
    ld   0xAA, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xAA, ac
    beq  ok_360
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_360:
    ld   0xAA, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    xor  0xAA, ac
    beq  ok_361
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_361:
    ld   0x31, x
    ld   0x55, [x]
    ld   [x], ac
    xor  0x55, ac
    beq  ok_362
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_362:
    ld   0xAA, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0xAA, ac
    beq  ok_363
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_363:
    ld   0x90, y
    ld   0x10, x
    ld   0xAA, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xAA, ac
    beq  ok_364
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_364:
    ld   0x55, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x55, ac
    beq  ok_365
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_365:
    ld   0x01, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    xor  0x01, ac
    beq  ok_366
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_366:
    ld   0x31, x
    ld   0xFE, [x]
    ld   [x], ac
    xor  0xFE, ac
    beq  ok_367
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_367:
    ld   0x01, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x01, ac
    beq  ok_368
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_368:
    ld   0x90, y
    ld   0x10, x
    ld   0x01, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x01, ac
    beq  ok_369
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_369:
    ld   0xFE, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xFE, ac
    beq  ok_370
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_370:
    ld   0x02, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    ld   pg_371 >> 8, y
    jmp  pg_371
#addr 0x3400
pg_371:
    xor  0x02, ac
    beq  ok_372
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_372:
    ld   0x31, x
    ld   0xFD, [x]
    ld   [x], ac
    xor  0xFD, ac
    beq  ok_373
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_373:
    ld   0x02, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x02, ac
    beq  ok_374
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_374:
    ld   0x90, y
    ld   0x10, x
    ld   0x02, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x02, ac
    beq  ok_375
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_375:
    ld   0xFD, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xFD, ac
    beq  ok_376
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_376:
    ld   0x04, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    xor  0x04, ac
    beq  ok_377
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_377:
    ld   0x31, x
    ld   0xFB, [x]
    ld   [x], ac
    xor  0xFB, ac
    beq  ok_378
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_378:
    ld   0x04, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x04, ac
    beq  ok_379
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_379:
    ld   0x90, y
    ld   0x10, x
    ld   0x04, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x04, ac
    beq  ok_380
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_380:
    ld   0xFB, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xFB, ac
    beq  ok_381
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_381:
    ld   0x08, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    xor  0x08, ac
    beq  ok_382
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_382:
    ld   0x31, x
    ld   0xF7, [x]
    ld   [x], ac
    xor  0xF7, ac
    beq  ok_383
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_383:
    ld   0x08, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x08, ac
    beq  ok_384
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_384:
    ld   0x90, y
    ld   0x10, x
    ld   0x08, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x08, ac
    beq  ok_385
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_385:
    ld   0xF7, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xF7, ac
    beq  ok_386
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_386:
    ld   0x10, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    ld   pg_387 >> 8, y
    jmp  pg_387
#addr 0x3500
pg_387:
    xor  0x10, ac
    beq  ok_388
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_388:
    ld   0x31, x
    ld   0xEF, [x]
    ld   [x], ac
    xor  0xEF, ac
    beq  ok_389
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_389:
    ld   0x10, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x10, ac
    beq  ok_390
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_390:
    ld   0x90, y
    ld   0x10, x
    ld   0x10, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x10, ac
    beq  ok_391
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_391:
    ld   0xEF, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xEF, ac
    beq  ok_392
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_392:
    ld   0x20, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    xor  0x20, ac
    beq  ok_393
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_393:
    ld   0x31, x
    ld   0xDF, [x]
    ld   [x], ac
    xor  0xDF, ac
    beq  ok_394
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_394:
    ld   0x20, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x20, ac
    beq  ok_395
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_395:
    ld   0x90, y
    ld   0x10, x
    ld   0x20, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x20, ac
    beq  ok_396
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_396:
    ld   0xDF, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xDF, ac
    beq  ok_397
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_397:
    ld   0x40, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    xor  0x40, ac
    beq  ok_398
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_398:
    ld   0x31, x
    ld   0xBF, [x]
    ld   [x], ac
    xor  0xBF, ac
    beq  ok_399
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_399:
    ld   0x40, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x40, ac
    beq  ok_400
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_400:
    ld   0x90, y
    ld   0x10, x
    ld   0x40, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x40, ac
    beq  ok_401
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_401:
    ld   0xBF, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0xBF, ac
    beq  ok_402
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_402:
    ld   0x80, ac
    ld   ac, [0x30]
    ld   0x00, ac
    ld   [0x30], ac
    ld   pg_403 >> 8, y
    jmp  pg_403
#addr 0x3600
pg_403:
    xor  0x80, ac
    beq  ok_404
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_404:
    ld   0x31, x
    ld   0x7F, [x]
    ld   [x], ac
    xor  0x7F, ac
    beq  ok_405
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_405:
    ld   0x80, x
    ld   x, [0x32]
    ld   [0x32], ac
    xor  0x80, ac
    beq  ok_406
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_406:
    ld   0x90, y
    ld   0x10, x
    ld   0x80, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x80, ac
    beq  ok_407
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_407:
    ld   0x7F, ac
    ld   ac, [y,x]
    ld   0x00, ac
    ld   [y,x], ac
    xor  0x7F, ac
    beq  ok_408
    ld   0xB4, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_408:
; test 14: ROM/RAM map register
    ld   0x01, y
    ld   0x10, x
    ld   0xFE, [y,x]
    ld   0x50, y
    ld   0x00, x
    ld   0x01, [y,x]
    ld   0x01, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0xFE, ac
    beq  ok_409
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_409:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0x01, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x01, ac
    beq  ok_410
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_410:
    ld   map_s1_b >> 8, y
    jmp  map_s1_b
t13b_411:
    ld   0x40, y
    ld   0x10, x
    ld   0xBF, [y,x]
    ld   0x50, y
    ld   0x00, x
    ld   0x04, [y,x]
    ld   0x40, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0xBF, ac
    beq  ok_412
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_412:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0x40, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x40, ac
    beq  ok_413
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_413:
    ld   0x7E, y
    ld   0x10, x
    ld   0x81, [y,x]
    ld   0x50, y
    ld   0x00, x
    ld   0x08, [y,x]
    ld   0x7E, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x81, ac
    beq  ok_414
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_414:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0x7E, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x7E, ac
    beq  ok_415
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_415:
    ld   0x80, y
    ld   0x10, x
    ld   0x7F, [y,x]
    ld   0x50, y
    ld   0x00, x
    ld   0x10, [y,x]
    ld   0x80, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x7F, ac
    beq  ok_416
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_416:
    ld   pg_417 >> 8, y
    jmp  pg_417
#addr 0x3700
pg_417:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0x80, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x80, ac
    beq  ok_418
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_418:
    ld   0xA0, y
    ld   0x10, x
    ld   0x5F, [y,x]
    ld   0x50, y
    ld   0x00, x
    ld   0x20, [y,x]
    ld   0xA0, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x5F, ac
    beq  ok_419
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_419:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0xA0, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0xA0, ac
    beq  ok_420
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_420:
    ld   0xC0, y
    ld   0x10, x
    ld   0x3F, [y,x]
    ld   0x50, y
    ld   0x00, x
    ld   0x40, [y,x]
    ld   0xC0, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x3F, ac
    beq  ok_421
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_421:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0xC0, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0xC0, ac
    beq  ok_422
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_422:
    ld   0xFE, y
    ld   0x10, x
    ld   0x18, [y,x]
    ld   0x50, y
    ld   0x00, x
    ld   0x80, [y,x]
    ld   0xFE, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x18, ac
    beq  ok_423
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_423:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0xFE, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0xE7, ac
    beq  ok_424
    ld   0xB8, ac
    ld   fail_h >> 8, y
    jmp  fail_h
ok_424:
    ld   core_back >> 8, y
    jmp  core_back

; section 3: map test for section 1, RAM address test
#addr 0x6000
fail_h3:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0x00, y
    jmp  ac
map_s1_a:
    ld   0x20, y
    ld   0x10, x
    ld   0xDF, [y,x]
    ld   0x50, y
    ld   0x00, x
    ld   0x02, [y,x]
    ld   0x20, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0xDF, ac
    beq  ok_425
    ld   0xB8, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_425:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0x20, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x20, ac
    beq  ok_426
    ld   0xB8, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_426:
    ld   t13b_196 >> 8, y
    jmp  t13b_196
map_s1_b:
    ld   0x20, y
    ld   0x10, x
    ld   0xDF, [y,x]
    ld   0x50, y
    ld   0x00, x
    ld   0x02, [y,x]
    ld   0x20, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0xDF, ac
    beq  ok_427
    ld   0xB8, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_427:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0x20, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x20, ac
    beq  ok_428
    ld   0xB8, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_428:
    ld   t13b_411 >> 8, y
    jmp  t13b_411
ram_addr_test:
; test 15: RAM address lines.  Writes a different byte at the base of
; each RAM chip and at base + 2^k, then reads them all back.
    ld   0x50, y
    ld   0x00, x
    ld   0xF7, [y,x]
    ld   0x00, y
    ld   0x00, x
    ld   0xA5, [y,x]
    ld   0x00, y
    ld   0x01, x
    ld   0x01, [y,x]
    ld   0x00, y
    ld   0x02, x
    ld   0x02, [y,x]
    ld   0x00, y
    ld   0x04, x
    ld   0x03, [y,x]
    ld   0x00, y
    ld   0x08, x
    ld   0x04, [y,x]
    ld   0x00, y
    ld   0x10, x
    ld   0x05, [y,x]
    ld   0x00, y
    ld   0x20, x
    ld   0x06, [y,x]
    ld   0x00, y
    ld   0x40, x
    ld   0x07, [y,x]
    ld   0x00, y
    ld   0x80, x
    ld   0x08, [y,x]
    ld   0x01, y
    ld   0x00, x
    ld   0x09, [y,x]
    ld   0x02, y
    ld   0x00, x
    ld   0x0A, [y,x]
    ld   0x04, y
    ld   0x00, x
    ld   0x0B, [y,x]
    ld   0x08, y
    ld   0x00, x
    ld   0x0C, [y,x]
    ld   0x10, y
    ld   0x00, x
    ld   0x0D, [y,x]
    ld   0x20, y
    ld   0x00, x
    ld   0x0E, [y,x]
    ld   0x40, y
    ld   0x00, x
    ld   0x0F, [y,x]
    ld   0x80, y
    ld   0x00, x
    ld   0x5A, [y,x]
    ld   0x80, y
    ld   0x01, x
    ld   0x41, [y,x]
    ld   0x80, y
    ld   0x02, x
    ld   0x42, [y,x]
    ld   0x80, y
    ld   0x04, x
    ld   0x43, [y,x]
    ld   0x80, y
    ld   0x08, x
    ld   0x44, [y,x]
    ld   0x80, y
    ld   0x10, x
    ld   0x45, [y,x]
    ld   pg_429 >> 8, y
    jmp  pg_429
#addr 0x6100
pg_429:
    ld   0x80, y
    ld   0x20, x
    ld   0x46, [y,x]
    ld   0x80, y
    ld   0x40, x
    ld   0x47, [y,x]
    ld   0x80, y
    ld   0x80, x
    ld   0x48, [y,x]
    ld   0x81, y
    ld   0x00, x
    ld   0x49, [y,x]
    ld   0x82, y
    ld   0x00, x
    ld   0x4A, [y,x]
    ld   0x84, y
    ld   0x00, x
    ld   0x4B, [y,x]
    ld   0x88, y
    ld   0x00, x
    ld   0x4C, [y,x]
    ld   0x90, y
    ld   0x00, x
    ld   0x4D, [y,x]
    ld   0xA0, y
    ld   0x00, x
    ld   0x4E, [y,x]
    ld   0xC0, y
    ld   0x00, x
    ld   0x4F, [y,x]
    ld   0x00, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0xA5, ac
    beq  ok_430
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_430:
    ld   0x00, y
    ld   0x01, x
    ld   [y,x], ac
    xor  0x01, ac
    beq  ok_431
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_431:
    ld   0x00, y
    ld   0x02, x
    ld   [y,x], ac
    xor  0x02, ac
    beq  ok_432
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_432:
    ld   0x00, y
    ld   0x04, x
    ld   [y,x], ac
    xor  0x03, ac
    beq  ok_433
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_433:
    ld   0x00, y
    ld   0x08, x
    ld   [y,x], ac
    xor  0x04, ac
    beq  ok_434
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_434:
    ld   0x00, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x05, ac
    beq  ok_435
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_435:
    ld   0x00, y
    ld   0x20, x
    ld   [y,x], ac
    xor  0x06, ac
    beq  ok_436
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_436:
    ld   0x00, y
    ld   0x40, x
    ld   [y,x], ac
    xor  0x07, ac
    beq  ok_437
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_437:
    ld   0x00, y
    ld   0x80, x
    ld   [y,x], ac
    xor  0x08, ac
    beq  ok_438
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_438:
    ld   0x01, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0x09, ac
    beq  ok_439
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_439:
    ld   0x02, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0x0A, ac
    beq  ok_440
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_440:
    ld   0x04, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0x0B, ac
    beq  ok_441
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_441:
    ld   0x08, y
    ld   0x00, x
    ld   [y,x], ac
    ld   pg_442 >> 8, y
    jmp  pg_442
#addr 0x6200
pg_442:
    xor  0x0C, ac
    beq  ok_443
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_443:
    ld   0x10, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0x0D, ac
    beq  ok_444
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_444:
    ld   0x20, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0x0E, ac
    beq  ok_445
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_445:
    ld   0x40, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0x0F, ac
    beq  ok_446
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_446:
    ld   0x80, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0x5A, ac
    beq  ok_447
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_447:
    ld   0x80, y
    ld   0x01, x
    ld   [y,x], ac
    xor  0x41, ac
    beq  ok_448
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_448:
    ld   0x80, y
    ld   0x02, x
    ld   [y,x], ac
    xor  0x42, ac
    beq  ok_449
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_449:
    ld   0x80, y
    ld   0x04, x
    ld   [y,x], ac
    xor  0x43, ac
    beq  ok_450
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_450:
    ld   0x80, y
    ld   0x08, x
    ld   [y,x], ac
    xor  0x44, ac
    beq  ok_451
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_451:
    ld   0x80, y
    ld   0x10, x
    ld   [y,x], ac
    xor  0x45, ac
    beq  ok_452
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_452:
    ld   0x80, y
    ld   0x20, x
    ld   [y,x], ac
    xor  0x46, ac
    beq  ok_453
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_453:
    ld   0x80, y
    ld   0x40, x
    ld   [y,x], ac
    xor  0x47, ac
    beq  ok_454
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_454:
    ld   0x80, y
    ld   0x80, x
    ld   [y,x], ac
    xor  0x48, ac
    beq  ok_455
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_455:
    ld   0x81, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0x49, ac
    beq  ok_456
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_456:
    ld   0x82, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0x4A, ac
    beq  ok_457
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_457:
    ld   0x84, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0x4B, ac
    beq  ok_458
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_458:
    ld   0x88, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0x4C, ac
    beq  ok_459
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_459:
    ld   pg_460 >> 8, y
    jmp  pg_460
#addr 0x6300
pg_460:
    ld   0x90, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0x4D, ac
    beq  ok_461
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_461:
    ld   0xA0, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0x4E, ac
    beq  ok_462
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_462:
    ld   0xC0, y
    ld   0x00, x
    ld   [y,x], ac
    xor  0x4F, ac
    beq  ok_463
    ld   0xBC, ac
    ld   fail_h3 >> 8, y
    jmp  fail_h3
ok_463:
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   t14b_210 >> 8, y
    jmp  t14b_210

; band tables
#addr 0x6E00
tbl4:
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x11, 0x11, 0x11, 0x11, 0x11, 0x22, 0x22, 0x22, 0x22, 0x22, 0x33
    #d8 0x33, 0x33, 0x33, 0x33, 0x44, 0x44, 0x44, 0x44, 0x44, 0x55, 0x55, 0x55, 0x55, 0x55, 0x66, 0x66
    #d8 0x66, 0x66, 0x66, 0x77, 0x77, 0x77, 0x77, 0x77, 0x88, 0x88, 0x88, 0x88, 0x88, 0x99, 0x99, 0x99
    #d8 0x99, 0x99, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xCC, 0xCC, 0xCC, 0xCC
    #d8 0xCC, 0xDD, 0xDD, 0xDD, 0xDD, 0xDD, 0xEE, 0xEE, 0xEE, 0xEE, 0xEE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
#addr 0x6F00
tbl2:
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    #d8 0x00, 0x00, 0x00, 0x00, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55
    #d8 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA
    #d8 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xFF, 0xFF, 0xFF, 0xFF
    #d8 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF

; main: library set-up, status screen, frame loop (section 4)
#addr 0x8100
main:
; copy LIB_RAM (ROM x1F00-x1FFF) into the RAM under it, map 00
    ld   0x50, y
    ld   0x00, x
    ld   0x00, [y,x]
    ld   0x1F, y
    ld   0x00, x
cp_464:
    ld   [y,x], ac
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    bne  cp_464
    ld   0x50, y
    ld   0x00, x
    ld   0x05, [y,x]
    ld   0x05, ac
    ld   ac, [MAP_SHADOW]
    ld   STACK_TOP, ac
    ld   ac, [SP]
    ld   0x00, ac
    ld   ac, [0x41]
    ld   0x00, ac
    ld   ac, [0x42]
    ld   0x00, ac
    ld   ac, [0x43]
    ld   0x00, ac
    ld   ac, [0x47]
    ld   0x00, ac
    ld   ac, [0x48]
    ld   0x00, ac
    ld   ac, [0x49]
    ld   0x00, ac
    ld   ac, [0x4A]
    ld   0x00, ac
    ld   ac, [0x4B]
    ld   0x00, ac
    ld   ac, [0x4C]
    ld   0x00, ac
    ld   ac, [0x4D]
    ld   0x00, ac
    ld   ac, [0x4E]
    ld   0x00, ac
    ld   ac, [0x50]
    ld   0x00, ac
    ld   ac, [0x54]
    ld   0x00, ac
    ld   ac, [0x55]
    ld   0x00, ac
    ld   ac, [0x56]
    ld   0x00, ac
    ld   ac, [0x57]
    ld   0x00, ac
    ld   ac, [0x5C]
    ld   0x00, ac
    ld   ac, [FRAME_LO]
    ld   ac, [FRAME_HI]
    ld   7, ac
    ld   ac, [0x4F]
    ld   0xEE, ac
    ld   ac, [0x53]
    ld   LINK_LO, x
    ld   ret_465, [x]
    ld   LINK_HI, x
    ld   ret_465 >> 8, [x]
    ld   port_init >> 8, y
    jmp  port_init
ret_465:
    ld   LINK_LO, x
    ld   ret_466, [x]
    ld   LINK_HI, x
    ld   ret_466 >> 8, [x]
    ld   snd_init >> 8, y
    jmp  snd_init
ret_466:
    ld   LINK_LO, x
    ld   ret_467, [x]
    ld   LINK_HI, x
    ld   ret_467 >> 8, [x]
    ld   con_clear >> 8, y
    jmp  con_clear
ret_467:
; mode bytes: rows 368-399 4 bpp, 400-415 2 bpp, 416-479 8 bpp (all 1x)
    ld   0x5B, y
    ld   0x90, x
mb_468:
    ld   0x02, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    xor  0xB0, ac
    bne  mb_468
    ld   0x5B, y
    ld   0xB0, x
mb_469:
    ld   0x01, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    xor  0xC0, ac
    bne  mb_469
    ld   0x5B, y
    ld   0xC0, x
mb_470:
    ld   0x03, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    bne  mb_470
; pixels: byte column c is at page x61 + 2c, rows 368-479 at x90-xFF
    ld   0x00, ac
    ld   ac, [0x58]
band_col:
    ld   [0x58], ac
    shl  ac
    add  0x61, ac
    ld   ac, [0x59]
    ld   tbl4 >> 8, y
    ld   [0x58], x
    ld   [y,x], ac
    ld   ac, [0x5A]
    ld   [0x59], y
    ld   0x90, x
bp_471:
    ld   [0x5A], ac
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    xor  0xB0, ac
    bne  bp_471
    ld   tbl2 >> 8, y
    ld   [0x58], x
    ld   [y,x], ac
    ld   ac, [0x5A]
    ld   pg_472 >> 8, y
    jmp  pg_472
#addr 0x8200
pg_472:
    ld   [0x59], y
    ld   0xB0, x
bp_473:
    ld   [0x5A], ac
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    xor  0xC0, ac
    bne  bp_473
; 8 bpp: colour = (row band) x 64 + (c and 63)
    ld   [0x58], ac
    and  0x3F, ac
    ld   ac, [0x5A]
    ld   [0x59], y
    ld   0xC0, x
b8_474:
    ld   x, ac
    and  0x30, ac
    shl  ac
    shl  ac
    or   [0x5A], ac
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    bne  b8_474
    ld   [0x58], ac
    inc
    ld   ac, [0x58]
    xor  80, ac
    beq  bd_475
    ld   band_col >> 8, y
    jmp  band_col
bd_475:
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   0, ac
    ld   ac, [CUR_ROW]
    ld   s_title, ac
    ld   ac, [R0]
    ld   s_title >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_476, [x]
    ld   LINK_HI, x
    ld   ret_476 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_476:
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   2, ac
    ld   ac, [CUR_ROW]
    ld   s_core, ac
    ld   ac, [R0]
    ld   s_core >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_477, [x]
    ld   LINK_HI, x
    ld   ret_477 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_477:
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   3, ac
    ld   ac, [CUR_ROW]
    ld   s_core2, ac
    ld   ac, [R0]
    ld   s_core2 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_478, [x]
    ld   LINK_HI, x
    ld   ret_478 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_478:
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   5, ac
    ld   ac, [CUR_ROW]
    ld   s_ram, ac
    ld   ac, [R0]
    ld   s_ram >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_479, [x]
    ld   LINK_HI, x
    ld   ret_479 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_479:
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   8, ac
    ld   ac, [CUR_ROW]
    ld   s_kbd, ac
    ld   ac, [R0]
    ld   s_kbd >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_480, [x]
    ld   LINK_HI, x
    ld   ret_480 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_480:
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   9, ac
    ld   ac, [CUR_ROW]
    ld   s_kbd2, ac
    ld   ac, [R0]
    ld   s_kbd2 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_481, [x]
    ld   LINK_HI, x
    ld   ret_481 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_481:
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   12, ac
    ld   ac, [CUR_ROW]
    ld   s_pad, ac
    ld   ac, [R0]
    ld   s_pad >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_482, [x]
    ld   LINK_HI, x
    ld   ret_482 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_482:
    ld   pg_483 >> 8, y
    jmp  pg_483
#addr 0x8300
pg_483:
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   14, ac
    ld   ac, [CUR_ROW]
    ld   s_sd, ac
    ld   ac, [R0]
    ld   s_sd >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_484, [x]
    ld   LINK_HI, x
    ld   ret_484 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_484:
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   15, ac
    ld   ac, [CUR_ROW]
    ld   s_sd2, ac
    ld   ac, [R0]
    ld   s_sd2 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_485, [x]
    ld   LINK_HI, x
    ld   ret_485 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_485:
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   17, ac
    ld   ac, [CUR_ROW]
    ld   s_mouse, ac
    ld   ac, [R0]
    ld   s_mouse >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_486, [x]
    ld   LINK_HI, x
    ld   ret_486 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_486:
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   18, ac
    ld   ac, [CUR_ROW]
    ld   s_mouse2, ac
    ld   ac, [R0]
    ld   s_mouse2 >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_487, [x]
    ld   LINK_HI, x
    ld   ret_487 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_487:
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   20, ac
    ld   ac, [CUR_ROW]
    ld   s_snd, ac
    ld   ac, [R0]
    ld   s_snd >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_488, [x]
    ld   LINK_HI, x
    ld   ret_488 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_488:
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   22, ac
    ld   ac, [CUR_ROW]
    ld   s_line, ac
    ld   ac, [R0]
    ld   s_line >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_489, [x]
    ld   LINK_HI, x
    ld   ret_489 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_489:
    ld   0, ac
    ld   ac, [CUR_COL]
    ld   44, ac
    ld   ac, [CUR_ROW]
    ld   s_bands, ac
    ld   ac, [R0]
    ld   s_bands >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_490, [x]
    ld   LINK_HI, x
    ld   ret_490 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_490:
    ld   32, ac
    ld   ac, [CUR_COL]
    ld   20, ac
    ld   ac, [CUR_ROW]
    ld   s_off, ac
    ld   ac, [R0]
    ld   s_off >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_491, [x]
    ld   LINK_HI, x
    ld   ret_491 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_491:
sd_try:
    ld   LINK_LO, x
    ld   ret_492, [x]
    ld   LINK_HI, x
    ld   ret_492 >> 8, [x]
    ld   sd_init >> 8, y
    jmp  sd_init
ret_492:
    ld   pg_493 >> 8, y
    jmp  pg_493
#addr 0x8400
pg_493:
    ld   ac, [0x51]
    beq  sdok_494
    ld   0xFF, ac
    ld   ac, [0x52]
    bra  sddn_495
sdok_494:
    ld   sd_mount >> 8, y
    jmp  sd_mount
sddn_495:
    ld   sd_show >> 8, y
    jmp  sd_show
sd_mount:
    ld   LINK_LO, x
    ld   ret_496, [x]
    ld   LINK_HI, x
    ld   ret_496 >> 8, [x]
    ld   fs_mount >> 8, y
    jmp  fs_mount
ret_496:
    ld   ac, [0x52]
sd_show:
    ld   17, ac
    ld   ac, [CUR_COL]
    ld   14, ac
    ld   ac, [CUR_ROW]
    ld   [0x51], ac
    ld   LINK_LO, x
    ld   ret_497, [x]
    ld   LINK_HI, x
    ld   ret_497 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_497:
    ld   31, ac
    ld   ac, [CUR_COL]
    ld   14, ac
    ld   ac, [CUR_ROW]
    ld   [0x52], ac
    ld   LINK_LO, x
    ld   ret_498, [x]
    ld   LINK_HI, x
    ld   ret_498 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_498:
; the first pass also starts the mouse; a retry (S) only does the card
    ld   [0x53], ac
    xor  0xEE, ac
    beq  mgo_499
    ld   frame_loop >> 8, y
    jmp  frame_loop
mgo_499:
    ld   LINK_LO, x
    ld   ret_500, [x]
    ld   LINK_HI, x
    ld   ret_500 >> 8, [x]
    ld   mouse_init >> 8, y
    jmp  mouse_init
ret_500:
    ld   ac, [0x53]
    ld   18, ac
    ld   ac, [CUR_COL]
    ld   17, ac
    ld   ac, [CUR_ROW]
    ld   [0x53], ac
    ld   LINK_LO, x
    ld   ret_501, [x]
    ld   LINK_HI, x
    ld   ret_501 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_501:
    ld   [LINE_LAST], ac
    ld   LINK_LO, x
    ld   ret_502, [x]
    ld   LINK_HI, x
    ld   ret_502 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
ret_502:
    ld   [FRAME_LO], ac
    ld   ac, [0x40]

; frame loop
#addr 0x9000
frame_loop:
wait_503:
    ld   LINK_LO, x
    ld   ret_504, [x]
    ld   LINK_HI, x
    ld   ret_504 >> 8, [x]
    ld   frame_poll >> 8, y
    jmp  frame_poll
ret_504:
    ld   ac, [0x5B]
    ld   [FRAME_LO], ac
    xor  [0x40], ac
    beq  wait_503
    ld   [FRAME_LO], ac
    ld   ac, [0x40]
    ld   LINK_LO, x
    ld   ret_505, [x]
    ld   LINK_HI, x
    ld   ret_505 >> 8, [x]
    ld   snd_update >> 8, y
    jmp  snd_update
ret_505:
    ld   LINK_LO, x
    ld   ret_506, [x]
    ld   LINK_HI, x
    ld   ret_506 >> 8, [x]
    ld   kbd_scan >> 8, y
    jmp  kbd_scan
ret_506:
key_loop:
    ld   LINK_LO, x
    ld   ret_507, [x]
    ld   LINK_HI, x
    ld   ret_507 >> 8, [x]
    ld   kbd_getc >> 8, y
    jmp  kbd_getc
ret_507:
    bne  key_508
    ld   keys_done >> 8, y
    jmp  keys_done
key_508:
    ld   ac, [0x5C]
    ld   [0x5C], ac
    xor  0x53, ac
    bne  nk_509
    ld   sd_key >> 8, y
    jmp  sd_key
nk_509:
    ld   [0x5C], ac
    xor  0x73, ac
    bne  nk_510
    ld   sd_key >> 8, y
    jmp  sd_key
nk_510:
    ld   [0x5C], ac
    xor  0x54, ac
    bne  nk_511
    ld   t_key >> 8, y
    jmp  t_key
nk_511:
    ld   [0x5C], ac
    xor  0x74, ac
    bne  nk_512
    ld   t_key >> 8, y
    jmp  t_key
nk_512:
echo_key:
; echo it on row 9 (control codes as a dot), wrapping at column 79
    ld   [0x5C], ac
    sub  0x20, ac
    bcc  pr_513
    ld   0x2E, ac
    ld   ac, [0x5C]
pr_513:
    ld   [0x4F], ac
    ld   ac, [CUR_COL]
    ld   9, ac
    ld   ac, [CUR_ROW]
    ld   [0x5C], ac
    ld   LINK_LO, x
    ld   ret_514, [x]
    ld   LINK_HI, x
    ld   ret_514 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
ret_514:
    ld   [0x4F], ac
    inc
    ld   ac, [0x4F]
    xor  80, ac
    bne  nw_515
    ld   7, ac
    ld   ac, [0x4F]
nw_515:
    ld   key_loop >> 8, y
    jmp  key_loop
sd_key:
    ld   sd_try >> 8, y
    jmp  sd_try
t_key:
    ld   [0x50], ac
    beq  ton_516
    ld   tone_off >> 8, y
    jmp  tone_off
ton_516:
    ld   1, ac
    ld   ac, [0x50]
    ld   0x11, ac
    ld   ac, [R0]
    ld   0x04, ac
    ld   ac, [R1]
    ld   0x00, ac
    ld   ac, [R2]
    ld   ac, [R3]
    ld   48, ac
    ld   LINK_LO, x
    ld   ret_517, [x]
    ld   LINK_HI, x
    ld   ret_517 >> 8, [x]
    ld   snd_tone >> 8, y
    jmp  snd_tone
ret_517:
    ld   32, ac
    ld   ac, [CUR_COL]
    ld   20, ac
    ld   ac, [CUR_ROW]
    ld   s_on, ac
    ld   ac, [R0]
    ld   s_on >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_518, [x]
    ld   LINK_HI, x
    ld   ret_518 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_518:
    ld   key_loop >> 8, y
    jmp  key_loop
tone_off:
    ld   0x00, ac
    ld   ac, [0x50]
    ld   LINK_LO, x
    ld   ret_519, [x]
    ld   LINK_HI, x
    ld   ret_519 >> 8, [x]
    ld   snd_stop >> 8, y
    jmp  snd_stop
ret_519:
    ld   pg_520 >> 8, y
    jmp  pg_520
#addr 0x9100
pg_520:
    ld   32, ac
    ld   ac, [CUR_COL]
    ld   20, ac
    ld   ac, [CUR_ROW]
    ld   s_off, ac
    ld   ac, [R0]
    ld   s_off >> 8, ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_521, [x]
    ld   LINK_HI, x
    ld   ret_521 >> 8, [x]
    ld   con_puts >> 8, y
    jmp  con_puts
ret_521:
    ld   key_loop >> 8, y
    jmp  key_loop
keys_done:
    ld   22, ac
    ld   ac, [CUR_COL]
    ld   8, ac
    ld   ac, [CUR_ROW]
    ld   [0xA0], ac
    ld   LINK_LO, x
    ld   ret_522, [x]
    ld   LINK_HI, x
    ld   ret_522 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_522:
    ld   25, ac
    ld   ac, [CUR_COL]
    ld   8, ac
    ld   ac, [CUR_ROW]
    ld   [0xA1], ac
    ld   LINK_LO, x
    ld   ret_523, [x]
    ld   LINK_HI, x
    ld   ret_523 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_523:
    ld   28, ac
    ld   ac, [CUR_COL]
    ld   8, ac
    ld   ac, [CUR_ROW]
    ld   [0xA2], ac
    ld   LINK_LO, x
    ld   ret_524, [x]
    ld   LINK_HI, x
    ld   ret_524 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_524:
    ld   31, ac
    ld   ac, [CUR_COL]
    ld   8, ac
    ld   ac, [CUR_ROW]
    ld   [0xA3], ac
    ld   LINK_LO, x
    ld   ret_525, [x]
    ld   LINK_HI, x
    ld   ret_525 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_525:
    ld   34, ac
    ld   ac, [CUR_COL]
    ld   8, ac
    ld   ac, [CUR_ROW]
    ld   [0xA4], ac
    ld   LINK_LO, x
    ld   ret_526, [x]
    ld   LINK_HI, x
    ld   ret_526 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_526:
    ld   37, ac
    ld   ac, [CUR_COL]
    ld   8, ac
    ld   ac, [CUR_ROW]
    ld   [0xA5], ac
    ld   LINK_LO, x
    ld   ret_527, [x]
    ld   LINK_HI, x
    ld   ret_527 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_527:
    ld   40, ac
    ld   ac, [CUR_COL]
    ld   8, ac
    ld   ac, [CUR_ROW]
    ld   [0xA6], ac
    ld   LINK_LO, x
    ld   ret_528, [x]
    ld   LINK_HI, x
    ld   ret_528 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_528:
    ld   43, ac
    ld   ac, [CUR_COL]
    ld   8, ac
    ld   ac, [CUR_ROW]
    ld   [0xA7], ac
    ld   LINK_LO, x
    ld   ret_529, [x]
    ld   LINK_HI, x
    ld   ret_529 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_529:
    ld   LINK_LO, x
    ld   ret_530, [x]
    ld   LINK_HI, x
    ld   ret_530 >> 8, [x]
    ld   pad_read >> 8, y
    jmp  pad_read
ret_530:
    ld   15, ac
    ld   ac, [CUR_COL]
    ld   12, ac
    ld   ac, [CUR_ROW]
    ld   [0x11], ac
    ld   LINK_LO, x
    ld   ret_531, [x]
    ld   LINK_HI, x
    ld   ret_531 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_531:
    ld   17, ac
    ld   ac, [CUR_COL]
    ld   12, ac
    ld   ac, [CUR_ROW]
    ld   [0x10], ac
    ld   pg_533 >> 8, y
    jmp  pg_533
#addr 0x9200
pg_533:
    ld   LINK_LO, x
    ld   ret_532, [x]
    ld   LINK_HI, x
    ld   ret_532 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_532:
    ld   27, ac
    ld   ac, [CUR_COL]
    ld   12, ac
    ld   ac, [CUR_ROW]
    ld   [0x13], ac
    ld   LINK_LO, x
    ld   ret_534, [x]
    ld   LINK_HI, x
    ld   ret_534 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_534:
    ld   29, ac
    ld   ac, [CUR_COL]
    ld   12, ac
    ld   ac, [CUR_ROW]
    ld   [0x12], ac
    ld   LINK_LO, x
    ld   ret_535, [x]
    ld   LINK_HI, x
    ld   ret_535 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_535:
    ld   [0x53], ac
    beq  mp_536
    ld   mouse_done >> 8, y
    jmp  mouse_done
mp_536:
    ld   LINK_LO, x
    ld   ret_537, [x]
    ld   LINK_HI, x
    ld   ret_537 >> 8, [x]
    ld   mouse_poll >> 8, y
    jmp  mouse_poll
ret_537:
    xor  1, ac
    beq  mm_538
    ld   mouse_show >> 8, y
    jmp  mouse_show
mm_538:
    ld   [0x54], ac
    ld   ac, [R0]
    ld   [0x55], ac
    ld   ac, [R1]
    ld   [0x56], ac
    ld   ac, [R2]
    ld   [0x57], ac
    ld   ac, [R3]
    ld   LINK_LO, x
    ld   ret_539, [x]
    ld   LINK_HI, x
    ld   ret_539 >> 8, [x]
    ld   mouse_move >> 8, y
    jmp  mouse_move
ret_539:
    ld   [R0], ac
    ld   ac, [0x54]
    ld   [R1], ac
    ld   ac, [0x55]
    ld   [R2], ac
    ld   ac, [0x56]
    ld   [R3], ac
    ld   ac, [0x57]
mouse_show:
    ld   24, ac
    ld   ac, [CUR_COL]
    ld   17, ac
    ld   ac, [CUR_ROW]
    ld   [0x54], ac
    ld   ac, [R0]
    ld   [0x55], ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_540, [x]
    ld   LINK_HI, x
    ld   ret_540 >> 8, [x]
    ld   con_dec16 >> 8, y
    jmp  con_dec16
ret_540:
    ld   0x20, ac
    ld   LINK_LO, x
    ld   ret_541, [x]
    ld   LINK_HI, x
    ld   ret_541 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
ret_541:
    ld   33, ac
    ld   ac, [CUR_COL]
    ld   17, ac
    ld   ac, [CUR_ROW]
    ld   [0x56], ac
    ld   ac, [R0]
    ld   [0x57], ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_542, [x]
    ld   LINK_HI, x
    ld   ret_542 >> 8, [x]
    ld   con_dec16 >> 8, y
    jmp  con_dec16
ret_542:
    ld   0x20, ac
    ld   LINK_LO, x
    ld   ret_543, [x]
    ld   LINK_HI, x
    ld   ret_543 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
ret_543:
    ld   49, ac
    ld   ac, [CUR_COL]
    ld   17, ac
    ld   ac, [CUR_ROW]
    ld   [MOUSE_B], ac
    ld   LINK_LO, x
    ld   ret_544, [x]
    ld   LINK_HI, x
    ld   ret_544 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_544:
mouse_done:
    ld   25, ac
    ld   ac, [CUR_COL]
    ld   22, ac
    ld   ac, [CUR_ROW]
    ld   [0x5B], ac
    ld   pg_546 >> 8, y
    jmp  pg_546
#addr 0x9300
pg_546:
    ld   LINK_LO, x
    ld   ret_545, [x]
    ld   LINK_HI, x
    ld   ret_545 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_545:
    ld   ram_page_test >> 8, y
    jmp  ram_page_test
rt_back:
    ld   9, ac
    ld   ac, [CUR_COL]
    ld   5, ac
    ld   ac, [CUR_ROW]
    ld   [0x44], ac
    ld   LINK_LO, x
    ld   ret_547, [x]
    ld   LINK_HI, x
    ld   ret_547 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_547:
    ld   23, ac
    ld   ac, [CUR_COL]
    ld   5, ac
    ld   ac, [CUR_ROW]
    ld   [0x47], ac
    ld   ac, [R0]
    ld   [0x48], ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_548, [x]
    ld   LINK_HI, x
    ld   ret_548 >> 8, [x]
    ld   con_dec16 >> 8, y
    jmp  con_dec16
ret_548:
    ld   0x20, ac
    ld   LINK_LO, x
    ld   ret_549, [x]
    ld   LINK_HI, x
    ld   ret_549 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
ret_549:
    ld   39, ac
    ld   ac, [CUR_COL]
    ld   5, ac
    ld   ac, [CUR_ROW]
    ld   [0x49], ac
    ld   ac, [R0]
    ld   [0x4A], ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_550, [x]
    ld   LINK_HI, x
    ld   ret_550 >> 8, [x]
    ld   con_dec16 >> 8, y
    jmp  con_dec16
ret_550:
    ld   0x20, ac
    ld   LINK_LO, x
    ld   ret_551, [x]
    ld   LINK_HI, x
    ld   ret_551 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
ret_551:
    ld   57, ac
    ld   ac, [CUR_COL]
    ld   5, ac
    ld   ac, [CUR_ROW]
    ld   [0x4B], ac
    ld   LINK_LO, x
    ld   ret_552, [x]
    ld   LINK_HI, x
    ld   ret_552 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_552:
    ld   59, ac
    ld   ac, [CUR_COL]
    ld   5, ac
    ld   ac, [CUR_ROW]
    ld   [0x4C], ac
    ld   LINK_LO, x
    ld   ret_553, [x]
    ld   LINK_HI, x
    ld   ret_553 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_553:
    ld   67, ac
    ld   ac, [CUR_COL]
    ld   5, ac
    ld   ac, [CUR_ROW]
    ld   [0x4D], ac
    ld   LINK_LO, x
    ld   ret_554, [x]
    ld   LINK_HI, x
    ld   ret_554 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_554:
    ld   75, ac
    ld   ac, [CUR_COL]
    ld   5, ac
    ld   ac, [CUR_ROW]
    ld   [0x4E], ac
    ld   LINK_LO, x
    ld   ret_555, [x]
    ld   LINK_HI, x
    ld   ret_555 >> 8, [x]
    ld   con_hex8 >> 8, y
    jmp  con_hex8
ret_555:
    ld   core_loop >> 8, y
    jmp  core_loop
core_back:
    ld   0x50, y
    ld   0x00, x
    ld   0x05, [y,x]
    ld   [0x41], ac
    inc
    ld   ac, [0x41]
    bne  nc_556
    ld   [0x42], ac
    inc
    ld   ac, [0x42]
nc_556:
    ld   58, ac
    ld   ac, [CUR_COL]
    ld   2, ac
    ld   ac, [CUR_ROW]
    ld   [0x41], ac
    ld   ac, [R0]
    ld   [0x42], ac
    ld   ac, [R1]
    ld   pg_558 >> 8, y
    jmp  pg_558
#addr 0x9400
pg_558:
    ld   LINK_LO, x
    ld   ret_557, [x]
    ld   LINK_HI, x
    ld   ret_557 >> 8, [x]
    ld   con_dec16 >> 8, y
    jmp  con_dec16
ret_557:
    ld   0x20, ac
    ld   LINK_LO, x
    ld   ret_559, [x]
    ld   LINK_HI, x
    ld   ret_559 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
ret_559:
    ld   66, ac
    ld   ac, [CUR_COL]
    ld   0, ac
    ld   ac, [CUR_ROW]
    ld   [0x08], ac
    ld   ac, [R0]
    ld   [0x09], ac
    ld   ac, [R1]
    ld   LINK_LO, x
    ld   ret_560, [x]
    ld   LINK_HI, x
    ld   ret_560 >> 8, [x]
    ld   con_dec16 >> 8, y
    jmp  con_dec16
ret_560:
    ld   0x20, ac
    ld   LINK_LO, x
    ld   ret_561, [x]
    ld   LINK_HI, x
    ld   ret_561 >> 8, [x]
    ld   con_putc >> 8, y
    jmp  con_putc
ret_561:
    ld   frame_loop >> 8, y
    jmp  frame_loop

; RAM page test, one page per frame (section 5)
#addr 0xA100
ram_page_test:
    ld   [0x43], x
    ld   rt_pages >> 8, y
    ld   [y,x], ac
    ld   ac, [0x44]
    ld   [0x44], y
    ld   0x00, x
rw_562:
    ld   0x00, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    bne  rw_562
    ld   0x00, x
rr_563:
    ld   [0x44], y
    ld   [y,x], ac
    ld   ac, [0x45]
    ld   0x00, ac
    ld   ac, [0x46]
    xor  [0x45], ac
    bne  rb_565
rn_564:
    ld   x, ac
    inc
    ld   ac, x
    bne  rr_563
    bra  rd_566
rb_565:
    ld   x, ac
    ld   ac, [0x4C]
    ld   ac, [0x30]
    ld   0, ac
    ld   ac, [0x31]
    ld   rt_err >> 8, y
    jmp  rt_err
rd_566:
    ld   [0x44], y
    ld   0x00, x
rw_567:
    ld   0xFF, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    bne  rw_567
    ld   0x00, x
rr_568:
    ld   [0x44], y
    ld   [y,x], ac
    ld   ac, [0x45]
    ld   0xFF, ac
    ld   ac, [0x46]
    xor  [0x45], ac
    bne  rb_570
rn_569:
    ld   x, ac
    inc
    ld   ac, x
    bne  rr_568
    bra  rd_571
rb_570:
    ld   x, ac
    ld   ac, [0x4C]
    ld   ac, [0x30]
    ld   1, ac
    ld   ac, [0x31]
    ld   rt_err >> 8, y
    jmp  rt_err
rd_571:
    ld   [0x44], y
    ld   0x00, x
rw_572:
    ld   0x55, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    bne  rw_572
    ld   0x00, x
rr_573:
    ld   [0x44], y
    ld   [y,x], ac
    ld   ac, [0x45]
    ld   0x55, ac
    ld   ac, [0x46]
    xor  [0x45], ac
    bne  rb_575
rn_574:
    ld   x, ac
    inc
    ld   ac, x
    bne  rr_573
    bra  rd_576
rb_575:
    ld   x, ac
    ld   ac, [0x4C]
    ld   ac, [0x30]
    ld   2, ac
    ld   ac, [0x31]
    ld   rt_err >> 8, y
    jmp  rt_err
rd_576:
    ld   [0x44], y
    ld   0x00, x
rw_577:
    ld   0xAA, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    bne  rw_577
    ld   0x00, x
rr_578:
    ld   [0x44], y
    ld   [y,x], ac
    ld   ac, [0x45]
    ld   0xAA, ac
    ld   ac, [0x46]
    xor  [0x45], ac
    bne  rb_580
rn_579:
    ld   x, ac
    inc
    ld   ac, x
    bne  rr_578
    bra  rd_581
rb_580:
    ld   x, ac
    ld   ac, [0x4C]
    ld   ac, [0x30]
    ld   3, ac
    ld   ac, [0x31]
    ld   rt_err >> 8, y
    jmp  rt_err
rd_581:
    ld   pg_582 >> 8, y
    jmp  pg_582
#addr 0xA200
pg_582:
    ld   [0x44], y
    ld   0x00, x
rw_583:
    ld   x, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    bne  rw_583
    ld   0x00, x
rr_584:
    ld   [0x44], y
    ld   [y,x], ac
    ld   ac, [0x45]
    ld   x, ac
    ld   ac, [0x46]
    xor  [0x45], ac
    bne  rb_586
rn_585:
    ld   x, ac
    inc
    ld   ac, x
    bne  rr_584
    bra  rd_587
rb_586:
    ld   x, ac
    ld   ac, [0x4C]
    ld   ac, [0x30]
    ld   4, ac
    ld   ac, [0x31]
    ld   rt_err >> 8, y
    jmp  rt_err
rd_587:
    ld   [0x44], y
    ld   0x00, x
rw_588:
    ld   x, ac
    xor  0xFF, ac
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, x
    bne  rw_588
    ld   0x00, x
rr_589:
    ld   [0x44], y
    ld   [y,x], ac
    ld   ac, [0x45]
    ld   x, ac
    xor  0xFF, ac
    ld   ac, [0x46]
    xor  [0x45], ac
    bne  rb_591
rn_590:
    ld   x, ac
    inc
    ld   ac, x
    bne  rr_589
    bra  rd_592
rb_591:
    ld   x, ac
    ld   ac, [0x4C]
    ld   ac, [0x30]
    ld   5, ac
    ld   ac, [0x31]
    ld   rt_err >> 8, y
    jmp  rt_err
rd_592:
    ld   [0x43], ac
    inc
    ld   ac, [0x43]
    xor  49, ac
    bne  rtw_593
    ld   0x00, ac
    ld   ac, [0x43]
rtw_593:
; a pass is done when the index wraps
    ld   [0x43], ac
    bne  rtp_594
    ld   rt_pass >> 8, y
    jmp  rt_pass
rtp_594:
    ld   rt_back >> 8, y
    jmp  rt_back
rt_pass:
    ld   [0x47], ac
    inc
    ld   ac, [0x47]
    bne  nc_595
    ld   [0x48], ac
    inc
    ld   ac, [0x48]
nc_595:
    ld   rt_back >> 8, y
    jmp  rt_back
rt_err:
    ld   [0x44], ac
    ld   ac, [0x4B]
    ld   [0x46], ac
    ld   ac, [0x4D]
    ld   [0x45], ac
    ld   ac, [0x4E]
    ld   [0x49], ac
    inc
    ld   ac, [0x49]
    bne  nc_596
    ld   [0x4A], ac
    inc
    ld   ac, [0x4A]
nc_596:
; back to the right pattern (its number is in T15B)
    ld   rt_dispatch >> 8, y
    jmp  rt_dispatch
; error return for pattern 0: X back, on to the next byte
rt_ret0:
    ld   [0x30], x
    ld   rn_564 >> 8, y
    jmp  rn_564
; error return for pattern 1: X back, on to the next byte
rt_ret1:
    ld   [0x30], x
    ld   rn_569 >> 8, y
    jmp  rn_569
; error return for pattern 2: X back, on to the next byte
rt_ret2:
    ld   [0x30], x
    ld   rn_574 >> 8, y
    jmp  rn_574
; error return for pattern 3: X back, on to the next byte
rt_ret3:
    ld   [0x30], x
    ld   rn_579 >> 8, y
    jmp  rn_579
; error return for pattern 4: X back, on to the next byte
rt_ret4:
    ld   [0x30], x
    ld   rn_585 >> 8, y
    jmp  rn_585
; error return for pattern 5: X back, on to the next byte
rt_ret5:
    ld   [0x30], x
    ld   rn_590 >> 8, y
    jmp  rn_590

; RAM test error return and tables
#addr 0xB000
rt_dispatch:
    ld   [0x31], ac
    xor  0, ac
    bne  dp_597
    ld   rt_ret0 >> 8, y
    jmp  rt_ret0
dp_597:
    ld   [0x31], ac
    xor  1, ac
    bne  dp_598
    ld   rt_ret1 >> 8, y
    jmp  rt_ret1
dp_598:
    ld   [0x31], ac
    xor  2, ac
    bne  dp_599
    ld   rt_ret2 >> 8, y
    jmp  rt_ret2
dp_599:
    ld   [0x31], ac
    xor  3, ac
    bne  dp_600
    ld   rt_ret3 >> 8, y
    jmp  rt_ret3
dp_600:
    ld   [0x31], ac
    xor  4, ac
    bne  dp_601
    ld   rt_ret4 >> 8, y
    jmp  rt_ret4
dp_601:
    ld   [0x31], ac
    xor  5, ac
    bne  dp_602
    ld   rt_ret5 >> 8, y
    jmp  rt_ret5
dp_602:
    ld   rt_ret0 >> 8, y
    jmp  rt_ret0
#addr 0xB200
rt_pages:
    #d8 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10
    #d8 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x40, 0x41
    #d8 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x54, 0x55, 0x56, 0x57, 0x58
    #d8 0x59

; strings
#addr 0xB300
s_title:
    #d "PLACARD BRING-UP ROM                                         FRAME", 0x00
s_core:
    #d "CPU CORE TESTS 1-16 PASSED.  REPEATED EVERY FRAME, LOOPS:", 0x00
s_core2:
    #d "A FAILED TEST STOPS THE CPU IN A LOOP AT x0080 + 4 x TEST (SEE BRINGUP.MD)", 0x00
s_ram:
    #d "RAM PAGE        PASSES          ERRORS          LAST BAD     WROTE    READ", 0x00
s_kbd:
    #d "KEYBOARD COLUMNS 0-7:", 0x00
s_kbd2:
    #d "TYPED:", 0x00
s_pad:
    #d "SNES PADS:  1:          2:", 0x00
s_sd:
    #d "SD CARD: SD_INIT      FS_MOUNT      (S = TRY AGAIN)", 0x00
s_sd2:
    #d "  SD_INIT 00 READY, 01 NO CARD, 02 DID NOT START, 03 UNUSABLE.  FS_MOUNT 00 OK", 0x00
s_mouse:
    #d "MOUSE: MOUSE_INIT      X        Y        BUTTONS", 0x00
s_mouse2:
    #d "  MOUSE_INIT 00 RUNNING, 01 NO MOUSE, 02 WRONG ANSWER", 0x00
s_snd:
    #d "SOUND: T = 1 KHZ TEST TONE, NOW", 0x00
s_on:
    #d "ON ", 0x00
s_off:
    #d "OFF", 0x00
s_line:
    #d "VIDEO LINE READ (V9:V2):", 0x00
s_bands:
    #d "BANDS BELOW: 16 COLORS (4 BPP), 4 COLORS (2 BPP), 256 COLORS (8 BPP)", 0x00
