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
;   - An immediate source cannot be stored to [0x30]: the one operand
;     byte can't be both the value and the address.  Use [x] or [y,x].
;   - [0x30] (zero page, [0,D]) forms emit the address as one operand
;     byte after the opcode.
;   - Immediate source emits the 8-bit value as one operand byte.
;   - Register names ac, x, y are reserved; don't use them as labels.
;   - shr takes only a destination (the source is the accumulator).
;
; ALU ops (I7:I5)
;   000 ld (pass B)  001 and  010 or  011 xor  100 add  101 sub
;   110 shr          111 branch / jump
;
; Branch / jump (I7:I5 = 111), type in M2:M0, target low byte follows
;   jmp  16-bit: PC low = operand, PC high = Y register (load Y first)
;   bra and conditional branches: 8-bit, PC low only (stay in the page)
;   Target may also be ac or x (computed branch), e.g.  jmp x
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

; branches allowed with a register target (bge excluded: with source
; 1x, MEM = 101 looks like a zero-page store to the State PLD)
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
        assert(v >= -128 && v <= 255)
        o @ d @ 0b00 @ v[7:0]
    }
    {o:alu} {v}, [x] =>
    {
        assert(v >= -128 && v <= 255)
        o @ 0b110 @ 0b00 @ v[7:0]
    }
    {o:alu} {v}, [y,x] =>
    {
        assert(v >= -128 && v <= 255)
        o @ 0b111 @ 0b00 @ v[7:0]
    }

    ; ---------------- register source -> RAM ----------------
    {o:alu} {s:reg_src}, [x]   => o @ 0b110 @ s
    {o:alu} {s:reg_src}, [y,x] => o @ 0b111 @ s
    {o:alu} {s:reg_src}, [{a}] =>
    {
        assert(a >= 0 && a <= 255)
        o @ 0b101 @ s @ a[7:0]
    }

    ; ---------------- memory source -> register ----------------
    {o:alu} [x], ac   => o @ 0b001 @ 0b01
    {o:alu} [y,x], ac => o @ 0b010 @ 0b01
    {o:alu} [{a}], {d:reg_dst} =>
    {
        assert(a >= 0 && a <= 255)
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
        assert(a >= 0 && a <= 255)
        0b110 @ 0b101 @ 0b10 @ a[7:0]
    }

    ; ---------------- jump: PC low from operand, PC high from Y ----------------
    jmp {t}         => 0b111 @ 0b000 @ 0b00 @ t[7:0]
    jmp {s:reg_src} => 0b111 @ 0b000 @ s

    ; ---------------- branches: PC low only ----------------
    ; the operand byte is at $+1, so PC high at execute = ($ + 2) >> 8
    {c:cond} {t} =>
    {
        assert((t >> 8) == (($ + 2) >> 8))
        0b111 @ c @ 0b00 @ t[7:0]
    }
    {c:cond_reg} {s:reg_src} => 0b111 @ c @ s
}
