; ============================================================
; placard_snd.asm - Placard sound driver: tones, noise, samples
; ============================================================
;
; The video circuit plays one byte of the sound buffer, x5DF3-x5FFF, on
; every scan line (docs/SOUND.md): 525 samples per frame at 31.469 kHz,
; 8-bit unsigned, 80h = silence.  This driver keeps that buffer filled
; with one sound at a time:
;
;     snd_init                  silence, call once at the start
;     snd_tone / snd_note       a square wave tone (snd_note: by note number)
;     snd_beep                  a short note that fades out
;     snd_noise                 noise, for drums, hits and explosions
;     snd_play                  8-bit unsigned samples from memory
;     snd_stop / snd_busy       stop, or ask whether a sound is playing
;     snd_update                write the samples; call it every frame
;
; Starting a sound only sets it up: snd_update writes its samples into
; the buffer behind the player, so a sound starts within about a frame.
; Tones and noise can run for a number of frames and fade by a step each
; frame; with neither they play until the next sound or snd_stop.
;
; placard_lib.asm includes this file.  The code is at SND_CODE (xD700),
; part of the library in ROM sections 6-7, which runs in place, so those
; sections must read the ROM when a program calls it.  The driver
; uses zero page x90-x9E (zeropage.asm) and T0-T3.
;
; Date: 10/19/2026
; ============================================================

SND_BUF   = 0x5DF3      ; first sample of the buffer
SND_SIL   = 0x80        ; silence


; ============================================================
; Page 1: update entry, init, stop, busy
; ============================================================
#addr SND_CODE

; ------------------------------------------------------------
; snd_update - write the samples the player has used since the last call
;   in:      -
;   out:     -
;   changes: AC, X, Y, T0-T3
;   clocks:  waits for the line read to change (up to 4 lines, 3200
;            clocks), then 30-80 per sample written, 525 samples a
;            frame: about 17.6k (samples), 25.3k (tone) or 40.8k (noise)
;            clocks per frame, 4-10 % of the CPU (test_snd.py).
;            Silence, once the buffer is clean, takes about 90.
;   Call it once every frame or more often, from anywhere in the frame.
;   A gap longer than a frame replays old samples for a moment.
; ------------------------------------------------------------
snd_update:
    ld   0x50, y
    ld   [SND_VEC], ac
    xor  gen_sil & 0xFF, ac
    bne  su_sync0
    ld   [SND_CLEAN], ac
    sub  2, ac
    blt  su_sync0
    ld   [y,x], ac              ; quiet: just follow the player, no wait
    ld   ac, [T0]
    clr  ac
    ld   ac, [T1]               ; T1 bit 7 = 0: quiet
    bra  su_pos
su_sync0:
    ld   [y,x], ac
    ld   ac, [T0]
su_sync:
    ld   [y,x], ac              ; wait for the line read to change, so
    xor  [T0], ac               ; the player is at the start of line 4r
    beq  su_sync
    ld   [y,x], ac
    ld   ac, [T0]
    ld   0x80, ac
    ld   ac, [T1]               ; T1 bit 7 = 1: write
su_pos:
    ld   [T0], ac               ; T3:T2 = the sample now playing,
    blt  su_p1                  ; x5C00 + 4r, at least x5DF3
    ld   0x5D, ac
    ld   ac, [T3]
    ld   [T0], ac
    shl
    shl
    ld   ac, [T2]
    xor  0xF0, ac
    bne  su_pd
    ld   0xF3, ac
    ld   ac, [T2]
    bra  su_pd
su_p1:
    and  0x40, ac
    beq  su_p2
    ld   0x5F, ac
    bra  su_p3
su_p2:
    ld   0x5E, ac
su_p3:
    ld   ac, [T3]
    ld   [T0], ac
    shl
    shl
    ld   ac, [T2]
su_pd:
    ld   [T1], ac
    blt  su_go
    ld   [T2], ac               ; quiet: the next sample to write is the
    ld   ac, [SND_PL]           ; one playing now
    ld   [T3], ac
    ld   ac, [SND_PH]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
su_go:
    ld   [T2], ac               ; write up to and including the sample
    inc                         ; playing now (its next lap): end = p + 1
    ld   ac, [T2]
    ld   gen_sil >> 8, y
    jmp  [SND_VEC]

; ------------------------------------------------------------
; snd_init - silence: fill the buffer with 80h and stop any sound
;   in:      -
;   out:     -
;   changes: AC, X, Y
;   clocks:  about 9000
; ------------------------------------------------------------
snd_init:
    ld   gen_sil & 0xFF, ac
    ld   ac, [SND_VEC]
    ld   SND_BUF >> 8, y
    ld   SND_BUF & 0xFF, x
si_a:
    ld   SND_SIL, ac
    ld   ac, [y,x]              ; x5DF3-x5DFF
    ld   x, ac
    inc
    ld   ac, x
    bne  si_a
    ld   0x5E, y
si_b:
    ld   SND_SIL, ac
    ld   ac, [y,x]              ; x5E00-x5EFF
    ld   x, ac
    inc
    ld   ac, x
    bne  si_b
    ld   0x5F, y
si_c:
    ld   SND_SIL, ac
    ld   ac, [y,x]              ; x5F00-x5FFF
    ld   x, ac
    inc
    ld   ac, x
    bne  si_c
    ld   SND_BUF & 0xFF, ac
    ld   ac, [SND_PL]
    ld   SND_BUF >> 8, ac
    ld   ac, [SND_PH]
    ld   2, ac
    ld   ac, [SND_CLEAN]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; snd_stop - stop the sound (the buffer goes silent within a frame)
;   in:      -
;   out:     -
;   changes: AC
;   clocks:  20
; ------------------------------------------------------------
snd_stop:
    ld   gen_sil & 0xFF, ac
    ld   ac, [SND_VEC]
    clr  ac
    ld   ac, [SND_CLEAN]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; ------------------------------------------------------------
; snd_busy - is a sound playing?
;   in:      -
;   out:     AC = 0 when silent, not 0 while a sound plays
;   changes: -
;   clocks:  17
; ------------------------------------------------------------
snd_busy:
    ld   [SND_VEC], ac
    xor  gen_sil & 0xFF, ac
    ld   [LINK_HI], y
    jmp  [LINK_LO]


; ============================================================
; Page 2: the fill loop and the sample makers
; ============================================================
; snd_update jumps to the sample maker in SND_VEC.  Each one leaves the
; next sample in AC and goes to su_tail, which stores it, steps the
; pointer and comes back through SND_VEC until it reaches T3:T2.  All of
; them must stay in this page.
#addr SND_CODE + 0x100

gen_sil:
    ld   SND_SIL, ac
    bra  su_tail

; square wave: phase += step x 2; the output is high while bit 15 is set
gen_tone:
    ld   [SND_ACL], ac
    add  [SND_INL], ac
    ld   ac, [SND_ACL]
    ld   [SND_ACH], ac
    bcc  gt_o
    inc                         ; the carry into the high byte
gt_o:
    add  [SND_INH], ac
    ld   ac, [SND_ACH]
    blt  gt_h
    ld   [SND_LOW], ac
    bra  su_tail
gt_h:
    ld   [SND_HIGH], ac
    bra  su_tail

; noise: a 16-bit LFSR (taps xB400) steps when the rate x 2 adds past 255
; (SND_INL = 256 - rate x 2, so a subtract with no borrow is a step)
gen_noise:
    ld   [SND_ACL], ac
    sub  [SND_INL], ac
    ld   ac, [SND_ACL]
    bcs  gn_out
    ld   [SND_INH], ac          ; low byte: shift right, bit 7 from high
    and  1, ac
    ld   ac, [T0]               ; the bit shifted out
    ld   [SND_INH], ac
    shr  ac
    ld   ac, [T1]
    ld   [SND_ACH], ac
    and  1, ac
    beq  gn_1
    ld   [T1], ac
    or   0x80, ac
    ld   ac, [T1]
gn_1:
    ld   [T1], ac
    ld   ac, [SND_INH]
    ld   [SND_ACH], ac
    shr  ac
    ld   ac, [SND_ACH]
    ld   [T0], ac
    beq  gn_out
    ld   [SND_ACH], ac
    xor  0xB4, ac
    ld   ac, [SND_ACH]
gn_out:
    ld   [SND_INH], ac
    and  1, ac
    beq  gn_l
    ld   [SND_HIGH], ac
    bra  su_tail
gn_l:
    ld   [SND_LOW], ac
    bra  su_tail

; samples: play [source], step the source when the rate x 2 adds past 255
; (SND_INL = 256 - rate x 2, as for noise)
gen_samp:
    ld   [SND_ACH], x
    ld   [SND_INH], y
    ld   [y,x], ac
    ld   ac, [T1]
    ld   [SND_ACL], ac
    sub  [SND_INL], ac
    ld   ac, [SND_ACL]
    bcc  gs_step
    ld   [T1], ac
    bra  su_tail
gs_step:
    ld   x, ac
    inc
    ld   ac, [SND_ACH]
    bne  gs_nc
    ld   [SND_INH], ac
    inc
    ld   ac, [SND_INH]
gs_nc:
    ld   [SND_LENL], ac         ; one byte fewer to play
    bne  gs_lo
    ld   [SND_LENH], ac
    dec
    ld   ac, [SND_LENH]
gs_lo:
    ld   [SND_LENL], ac
    dec
    ld   ac, [SND_LENL]
    bne  gs_out
    ld   [SND_LENH], ac
    bne  gs_out
    ld   gen_sil & 0xFF, ac     ; the last byte: silence from here on
    ld   ac, [SND_VEC]
gs_out:
    ld   [T1], ac
    ; falls into su_tail

; store AC at the pointer, step it (x5FFF wraps to x5DF3) and go on
; until the pointer reaches T3:T2
su_tail:
    ld   [SND_PH], y
    ld   [SND_PL], x
    ld   ac, [y,x]
    ld   x, ac
    inc
    ld   ac, [SND_PL]
    beq  su_page
su_cmp:
    xor  [T2], ac
    bne  [SND_VEC]
    ld   [SND_PH], ac
    xor  [T3], ac
    bne  [SND_VEC]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
su_page:
    ld   [SND_PH], ac
    inc
    ld   ac, [SND_PH]
    xor  0x60, ac
    beq  su_lap
    ld   [SND_PL], ac
    bra  su_cmp
su_lap:
    ld   su_lap2 >> 8, y        ; a whole buffer (one frame) written:
    jmp  su_lap2                ; frames and fading, in page 5

; ============================================================
; Page 3: starting sounds
; ============================================================
#addr SND_CODE + 0x200

; ------------------------------------------------------------
; snd_tone - start a square wave tone
;   in:      R1:R0 = step = frequency in Hz x 1.0413 (32768 / 31469),
;            1-32767; snd_note gives it for a note
;            AC = volume, 0-127 (the wave swings 80h +- volume)
;            R2 = frames to play, 0 = until stopped
;            R3 = volume taken off every frame, 0 = none (it stops at 0)
;   out:     -
;   changes: AC
;   clocks:  about 110
; ------------------------------------------------------------
snd_tone:
    and  0x7F, ac
    ld   ac, [SND_VOL]
    ld   [R1], ac               ; the phase adds step x 2
    shl
    ld   ac, [SND_INH]
    ld   [R0], ac
    shl                         ; carry = R0 bit 7
    ld   ac, [SND_INL]
    bcc  st_lev
    ld   [SND_INH], ac
    or   1, ac
    ld   ac, [SND_INH]
    bra  st_lev
st_go:                          ; AC = the sample maker
    ld   ac, [SND_VEC]
    clr  ac
    ld   ac, [SND_CLEAN]
    ld   [LINK_HI], y
    jmp  [LINK_LO]
st_lev:                         ; levels, time and fade, then start
    ld   [SND_VOL], ac
    add  SND_SIL, ac
    ld   ac, [SND_HIGH]
    ld   SND_SIL, ac
    sub  [SND_VOL], ac
    ld   ac, [SND_LOW]
    ld   [R2], ac
    ld   ac, [SND_FRAMES]
    ld   [R3], ac
    ld   ac, [SND_DECAY]
    ld   gen_tone & 0xFF, ac
    bra  st_go

; ------------------------------------------------------------
; snd_noise - start noise
;   in:      AC = volume, 0-127
;            R0 = rate, 1-128: how often the noise changes, in 128ths of
;            the line rate (128 = 31.5 kHz, hiss; 8 = 2 kHz, a rumble)
;            R2 = frames to play, 0 = until stopped
;            R3 = volume taken off every frame, 0 = none
;   out:     -
;   changes: AC
;   clocks:  about 110
;   The noise starts from the same seed every time, so a sound effect
;   sounds the same each time it plays.
; ------------------------------------------------------------
#addr SND_CODE + 0x23C            ; entry addresses stay fixed (carry flag rewrite left a gap)
snd_noise:
    and  0x7F, ac
    ld   ac, [SND_VOL]
    ld   [R0], ac
    bra  sn_rate
sn_back:
    ld   0xAC, ac
    ld   ac, [SND_ACH]
    ld   0xE1, ac
    ld   ac, [SND_INH]
    ld   [SND_VOL], ac
    add  SND_SIL, ac
    ld   ac, [SND_HIGH]
    ld   SND_SIL, ac
    sub  [SND_VOL], ac
    ld   ac, [SND_LOW]
    ld   [R2], ac
    ld   ac, [SND_FRAMES]
    ld   [R3], ac
    ld   ac, [SND_DECAY]
    ld   gen_noise & 0xFF, ac
    bra  st_go

; ------------------------------------------------------------
; snd_play - play 8-bit unsigned samples (80h = silence) from memory
;   in:      R1:R0 = address of the first sample (RAM or ROM)
;            R3:R2 = number of samples, 1-65535 (0 stops the sound)
;            AC = rate, 1-128, in 128ths of the line rate: 128 plays a
;            sample per line (31.5 kHz), 64 = 15.7 kHz, 33 = 8.1 kHz,
;            32 = 7.9 kHz
;   out:     -
;   changes: AC
;   clocks:  about 90
; ------------------------------------------------------------
snd_play:
    bra  sp_rate
sp_back:
    ld   [R0], ac
    ld   ac, [SND_ACH]
    ld   [R1], ac
    ld   ac, [SND_INH]
    ld   [R2], ac
    ld   ac, [SND_LENL]
    or   [R3], ac
    beq  sp_none
    ld   [R3], ac
    ld   ac, [SND_LENH]
    clr  ac
    ld   ac, [SND_ACL]
    ld   ac, [SND_FRAMES]
    ld   ac, [SND_DECAY]
    ld   gen_samp & 0xFF, ac
    bra  st_go
sp_none:
    ld   gen_sil & 0xFF, ac
    bra  st_go

; ------------------------------------------------------------
; snd_beep - a short note that fades out (volume 96, 12 frames)
;   in:      AC = note number, 0-127, as snd_note (69 = A 440 Hz)
;   out:     R1:R0 = the note's step, R2 = 12, R3 = 8
;   changes: AC, X, Y
;   clocks:  about 180
; ------------------------------------------------------------
snd_beep:
    and  0x7F, ac
    ld   ac, x
    ld   snd_notes >> 8, y
    ld   [y,x], ac
    ld   ac, [R0]
    ld   x, ac
    or   0x80, ac
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   12, ac
    ld   ac, [R2]
    ld   8, ac
    ld   ac, [R3]
    ld   96, ac
    ld   snd_tone >> 8, y
    jmp  snd_tone

; ------------------------------------------------------------
; snd_note - the tone step for a note
;   in:      AC = note number, 0-127, as MIDI: 60 = middle C (261.6 Hz),
;            69 = A (440 Hz), 12 notes per octave
;   out:     R1:R0 = step for snd_tone
;   changes: AC, X
;   clocks:  about 50
; ------------------------------------------------------------
snd_note:
    and  0x7F, ac
    ld   ac, x
    ld   snd_notes >> 8, y
    ld   [y,x], ac
    ld   ac, [R0]
    ld   x, ac
    or   0x80, ac
    ld   ac, x
    ld   [y,x], ac
    ld   ac, [R1]
    ld   [LINK_HI], y
    jmp  [LINK_LO]

; SND_INL = 256 - rate x 2, for noise and samples (rate 128 gives 0)
sn_rate:
    shl
    xor  0xFF, ac
    inc
    ld   ac, [SND_INL]
    bra  sn_back
sp_rate:
    shl
    xor  0xFF, ac
    inc
    ld   ac, [SND_INL]
    bra  sp_back


; ============================================================
; Page 4: note table, step = 440 x 2^((n - 69) / 12) x 32768 / 31469
; ============================================================
#addr SND_CODE + 0x300

snd_notes:
    #d8 0x09, 0x09, 0x0A, 0x0A, 0x0B, 0x0B, 0x0C, 0x0D   ; lo 0-7
    #d8 0x0E, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14   ; lo 8-15
    #d8 0x15, 0x17, 0x18, 0x1A, 0x1B, 0x1D, 0x1E, 0x20   ; lo 16-23
    #d8 0x22, 0x24, 0x26, 0x28, 0x2B, 0x2D, 0x30, 0x33   ; lo 24-31
    #d8 0x36, 0x39, 0x3D, 0x40, 0x44, 0x48, 0x4C, 0x51   ; lo 32-39
    #d8 0x56, 0x5B, 0x60, 0x66, 0x6C, 0x73, 0x79, 0x81   ; lo 40-47
    #d8 0x88, 0x90, 0x99, 0xA2, 0xAC, 0xB6, 0xC1, 0xCC   ; lo 48-55
    #d8 0xD8, 0xE5, 0xF3, 0x01, 0x10, 0x21, 0x32, 0x44   ; lo 56-63
    #d8 0x57, 0x6C, 0x81, 0x98, 0xB0, 0xCA, 0xE5, 0x02   ; lo 64-71
    #d8 0x21, 0x41, 0x64, 0x88, 0xAE, 0xD7, 0x03, 0x30   ; lo 72-79
    #d8 0x61, 0x94, 0xCB, 0x05, 0x42, 0x82, 0xC7, 0x10   ; lo 80-87
    #d8 0x5D, 0xAF, 0x05, 0x61, 0xC2, 0x29, 0x96, 0x09   ; lo 88-95
    #d8 0x83, 0x05, 0x8E, 0x20, 0xBA, 0x5D, 0x0A, 0xC1   ; lo 96-103
    #d8 0x84, 0x51, 0x2B, 0x12, 0x07, 0x0A, 0x1D, 0x40   ; lo 104-111
    #d8 0x74, 0xBA, 0x14, 0x83, 0x07, 0xA3, 0x57, 0x24   ; lo 112-119
    #d8 0x0E, 0x14, 0x39, 0x7F, 0xE7, 0x75, 0x29, 0x06   ; lo 120-127
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00   ; hi 0-7
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00   ; hi 8-15
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00   ; hi 16-23
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00   ; hi 24-31
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00   ; hi 32-39
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00   ; hi 40-47
    #d8 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00   ; hi 48-55
    #d8 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01   ; hi 56-63
    #d8 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x02   ; hi 64-71
    #d8 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x03, 0x03   ; hi 72-79
    #d8 0x03, 0x03, 0x03, 0x04, 0x04, 0x04, 0x04, 0x05   ; hi 80-87
    #d8 0x05, 0x05, 0x06, 0x06, 0x06, 0x07, 0x07, 0x08   ; hi 88-95
    #d8 0x08, 0x09, 0x09, 0x0A, 0x0A, 0x0B, 0x0C, 0x0C   ; hi 96-103
    #d8 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14   ; hi 104-111
    #d8 0x15, 0x16, 0x18, 0x19, 0x1B, 0x1C, 0x1E, 0x20   ; hi 112-119
    #d8 0x22, 0x24, 0x26, 0x28, 0x2A, 0x2D, 0x30, 0x33   ; hi 120-127


; ============================================================
; Page 5: once per buffer lap (one frame of samples) for snd_update
; ============================================================
#addr SND_CODE + 0x400

; the pointer wrapped from x5FFF: go back to x5DF3, count the frame,
; fade, and stop the sound when its time is up; back to su_cmp with AC
; = the new pointer low byte
su_lap2:
    ld   SND_BUF >> 8, ac
    ld   ac, [SND_PH]
    ld   SND_BUF & 0xFF, ac
    ld   ac, [SND_PL]
    ld   [SND_VEC], ac
    xor  gen_sil & 0xFF, ac
    bne  su_snd
    ld   [SND_CLEAN], ac        ; silent: count clean laps, up to 2
    sub  2, ac
    bcc  su_end
    ld   [SND_CLEAN], ac
    inc
    ld   ac, [SND_CLEAN]
    bra  su_end
su_snd:
    ld   [SND_FRAMES], ac
    beq  su_dec                 ; 0: no time limit
    dec
    ld   ac, [SND_FRAMES]
    beq  su_off
su_dec:
    ld   [SND_DECAY], ac
    beq  su_end
    ld   [SND_VOL], ac
    sub  [SND_DECAY], ac
    blt  su_off
    beq  su_off
    ld   ac, [SND_VOL]
    add  SND_SIL, ac
    ld   ac, [SND_HIGH]
    ld   SND_SIL, ac
    sub  [SND_VOL], ac
    ld   ac, [SND_LOW]
    bra  su_end
su_off:
    ld   gen_sil & 0xFF, ac
    ld   ac, [SND_VEC]
    clr  ac
    ld   ac, [SND_CLEAN]
su_end:
    ld   [SND_PL], ac
    ld   su_cmp >> 8, y
    jmp  su_cmp

