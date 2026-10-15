; ============================================================
; Placard CPU - customasm rules
; ============================================================
;
; Instruction byte:   [ I7 I6 I5 | M2 M1 M0 | S1 S0 ]
;                       ALU op     mem/dest    source
;
; Syntax:   op  source, destination        (source first)
;
; SOURCE (S1:S0)                       DESTINATION / ADDRESS MODE (M2:M0)
;   00  immediate  ->  12  (number)       000  ac      address [0,D]
;   01  memory     ->  [0x30] [x] [y,x]   001  ac      address [0,X]
;   10  accumulator -> ac                 010  ac      address [Y,X]
;   11  X register  -> x                  011  x       address [0,D]
;                                         100  y       address [0,D]
;                                         101  [0x30]  store, address [0,D]
;                                         110  [x]     store, address [0,X]
;                                         111  [y,x]   store, address [Y,X]
;
; Notes
;   - The destination field also selects the address mode, so a memory
;     source can only be combined with the destinations in the table:
;         ld  [0x30], ac | x | y      ld  [x], ac      ld  [y,x], ac
;     and a memory source stored back to RAM must use the same address.
;     That only works for the indexed forms, because the read overwrites
;     D, which holds a zero-page address:
;         add [x], [x]   add [y,x], [y,x]
;   - <op> n, [n] stores an immediate to zero page, but the one operand
;     byte is both the value and the address (it writes n at address n),
;     so write the same number twice:  ld 0x30, [0x30]
;     The assembler does NOT check that the two numbers match (the
;     address is what gets emitted).  The ALU op doesn't change what is
;     written (RAM takes the source bus, not the ALU result), so all
;     six ops accept it.  For an independent value and address use
;     ld n, ac then ld ac, [0xNN], or ld n, [x] / ld n, [y,x].
;   - This file uses no assert() (older customasm builds, including the
;     web version, reject it), so nothing checks operand ranges:
;     values are truncated to 8 bits, and a branch target must be in
;     the same 256-byte page as the branch (PC high is not changed).
;   - [0x30] (zero page, [0,D]) forms emit the address as one operand
;     byte after the opcode.
;   - Immediate source emits the 8-bit value as one operand byte.
;   - Register names ac, x, y are reserved; don't use them as labels.
;   - shr takes only a destination (the source is the accumulator).
;
;   - Aliases (the ALU's A input is always AC, so some ops with AC as
;     the source collapse into useful one-byte instructions):
;         nop        ld ac, ac           AC = AC
;         shl ac     add ac, ac          AC = AC + AC
;         clr ac|x|y xor ac, d           d = AC xor AC = 0
;         inc / dec  add 1, ac / sub 1, ac
;         not        xor 255, ac         AC = ~AC
;     shl, clr, nop are one byte, 2 clocks.  The full forms still
;     assemble too.  There is no neg (the ALU only does AC - B), and
;     shl only works on AC because RAM stores take the source bus,
;     not the ALU result.
;
; ALU ops (I7:I5)
;   000 ld (pass B)  001 and  010 or  011 xor  100 add  101 sub
;   110 shr          111 branch / jump
;
; Branch / jump (I7:I5 = 111), type in M2:M0, target low byte follows
;   jmp  16-bit: PC low = operand, PC high = Y register (load Y first)
;   bra and conditional branches: 8-bit, PC low only (stay in the page)
;   Target may also be ac or x (computed branch), e.g.  jmp x
;   Target may also come from memory (indirect branch, source 01).  The
;   branch type in M2:M0 also picks the address mode, so each type
;   accepts one memory form:
;       jmp [0xNN]   bne [0xNN]   beq [0xNN]     zero page, [0,D]
;       bgt [x]      ble [x]                     [0,X]
;       blt [y,x]    bra [y,x]                   [Y,X]
;   bge has no memory form.  MEM = 101 is also the zero-page store
;   code, and the State PLD can't fetch the zero-page address for a
;   branch.  bge with an immediate, ac or x target works.  bge ac and
;   bge x are 2 bytes: the State PLD treats them like a zero-page
;   store and fetches a byte after the opcode, so a pad byte (00)
;   follows (State PLD rev 11).
; ============================================================

#bankdef rom
{
    #bits 8
    #addr 0
    #size 0x10000
    #outp 0
}


#subruledef alu
{
    ld  => 0b000
    and => 0b001
    or  => 0b010
    xor => 0b011
    add => 0b100
    sub => 0b101
}

; register sources (no operand byte)
#subruledef reg_src
{
    ac => 0b10
    x  => 0b11
}

; register destinations ([0,D] address mode when used with a memory source)
#subruledef reg_dst
{
    ac => 0b000
    x  => 0b011
    y  => 0b100
}

; conditional / 8-bit branches
#subruledef cond
{
    bgt => 0b001
    blt => 0b010
    bne => 0b011
    beq => 0b100
    bge => 0b101
    ble => 0b110
    bra => 0b111
}

; the same without bge, whose ac / x form has a pad byte
#subruledef cond_reg
{
    bgt => 0b001
    blt => 0b010
    bne => 0b011
    beq => 0b100
    ble => 0b110
    bra => 0b111
}


#ruledef
{
    ; ---------------- register source -> register ----------------
    {o:alu} {s:reg_src}, {d:reg_dst} => o @ d @ s

    ; ---------------- immediate source ----------------
    {o:alu} {v}, {d:reg_dst} =>
    {
        o @ d @ 0b00 @ v[7:0]
    }
    {o:alu} {v}, [x] =>
    {
        o @ 0b110 @ 0b00 @ v[7:0]
    }
    {o:alu} {v}, [y,x] =>
    {
        o @ 0b111 @ 0b00 @ v[7:0]
    }

    ; immediate -> zero page: value and address share the operand byte
    {o:alu} {v}, [{a}] =>
    {
        o @ 0b101 @ 0b00 @ a[7:0]
    }

    ; ---------------- register source -> RAM ----------------
    {o:alu} {s:reg_src}, [x]   => o @ 0b110 @ s
    {o:alu} {s:reg_src}, [y,x] => o @ 0b111 @ s
    {o:alu} {s:reg_src}, [{a}] =>
    {
        o @ 0b101 @ s @ a[7:0]
    }

    ; ---------------- memory source -> register ----------------
    {o:alu} [x], ac   => o @ 0b001 @ 0b01
    {o:alu} [y,x], ac => o @ 0b010 @ 0b01
    {o:alu} [{a}], {d:reg_dst} =>
    {
        o @ d @ 0b01 @ a[7:0]
    }

    ; ---------------- memory source -> same RAM location ----------------
    {o:alu} [x], [x]     => o @ 0b110 @ 0b01
    {o:alu} [y,x], [y,x] => o @ 0b111 @ 0b01

    ; ---------------- shift right (source is the accumulator) ----------------
    shr {d:reg_dst} => 0b110 @ d @ 0b10
    shr [x]         => 0b110 @ 0b110 @ 0b10
    shr [y,x]       => 0b110 @ 0b111 @ 0b10
    shr [{a}]       =>
    {
        0b110 @ 0b101 @ 0b10 @ a[7:0]
    }

    ; ---------------- aliases ----------------
    nop         => 0b000 @ 0b000 @ 0b10      ; ld  ac, ac
    shl ac      => 0b100 @ 0b000 @ 0b10      ; add ac, ac
    shl         => 0b100 @ 0b000 @ 0b10
    clr {d:reg_dst} => 0b011 @ d @ 0b10      ; xor ac, d
    inc         => 0b100 @ 0b000 @ 0b00 @ 0x01   ; add 1, ac
    dec         => 0b101 @ 0b000 @ 0b00 @ 0x01   ; sub 1, ac
    not         => 0b011 @ 0b000 @ 0b00 @ 0xFF   ; xor 255, ac

    ; ---------------- jump: PC low from operand, PC high from Y ----------------
    ; register forms first, so "ac" / "x" never get read as a label
    jmp {s:reg_src} => 0b111 @ 0b000 @ s
    jmp {t}         => 0b111 @ 0b000 @ 0b00 @ t[7:0]

    ; ---------------- branches: PC low only ----------------
    ; the operand byte is at $+1, so PC high at execute = ($ + 2) >> 8
    {c:cond_reg} {s:reg_src} => 0b111 @ c @ s
    bge {s:reg_src}          => 0b111 @ 0b101 @ s @ 0x00   ; pad byte
    {c:cond} {t} =>
    {
        0b111 @ c @ 0b00 @ t[7:0]
    }

    ; ---------------- indirect branches: PC low from memory ----------------
    ; source 01.  The memory field is the branch type, so it also fixes
    ; the address mode used to read the target byte.
    jmp [{a}] =>
    {
        0b111 @ 0b000 @ 0b01 @ a[7:0]
    }
    bne [{a}] =>
    {
        0b111 @ 0b011 @ 0b01 @ a[7:0]
    }
    beq [{a}] =>
    {
        0b111 @ 0b100 @ 0b01 @ a[7:0]
    }
    bgt [x]   => 0b111 @ 0b001 @ 0b01
    ble [x]   => 0b111 @ 0b110 @ 0b01
    blt [y,x] => 0b111 @ 0b010 @ 0b01
    bra [y,x] => 0b111 @ 0b111 @ 0b01
}
