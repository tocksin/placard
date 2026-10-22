#!/usr/bin/env python3
"""
menu_hook.py - the program menu's hook for the RAM programs (cpu_test,
pi_spigot, mandelbrot, game_of_life), shared by their generators.

The menu ROM (docs/MENU.md) takes the machine back from a program when Esc
is pressed or, while it rotates through the programs, when the program's
time is up.  A ROM program calls the library's menu_poll for that
(placard_menu.asm).  The RAM programs run with map FF, where the library
can't be reached, so each carries its own copy of the check, made here.
It talks to the menu through the same menu block at RAM x5D00 (see
placard_menu.asm for the layout) and does nothing when the block has no
"MNU" mark, so the programs still run by themselves.

Two routines, each in its own block (each fits in one page):

    hk_poll   call it at least every 12 ms (95 steps of the line read):
              it reads the line, and once per frame checks Esc and counts
              down the time left (rotating only).  Changes AC, X, Y.
    hk_done   the program has finished a run (and shown its result): when
              rotating, go on to the next program now.  Changes AC, X, Y.
    hk_hold   the program has finished and shows its result from now on:
              when rotating, leave within MB_HOLD frames (the menu sets
              10 s), unless the time is up sooner.  Changes AC, X, Y.
    Without the menu, or picked from the menu, hk_done and hk_hold just
    return.

They return with  ld [reth], y / jmp [ret]  through two zero-page bytes the
program names (its own call convention).  When the program must stop they
put the reason in MB_WHY and jump to the menu's exit code at x5D20, which
maps the ROM back in and returns to the menu.

    blocks = hook_blocks(ret_zp, reth_zp)   -> [(name, [(kind, text), ...])]
    kind 'L' = label, 'I' = instruction

Date: 10/22/2026
"""

MENU_BLK = 0x5D00
MB_MODE, MB_LEFT, MB_LAST, MB_WHY = 0x03, 0x04, 0x06, 0x09
MB_CUR, MB_HOLD = 0x0A, 0x0B        # the hook's scratch byte; frames to show a result
MB_EXIT = 0x20
WHY_ESC, WHY_NEXT = 1, 2
MAGIC = (0x4D, 0x4E, 0x55)          # "MNU"
PORT, P_IDLE, P_COL0 = 0x52, 0xEB, 0x0F


def _magic(I, fail):
    I('ld 0x%02X, y' % (MENU_BLK >> 8))
    for k, ch in enumerate(MAGIC):
        I('ld 0x%02X, x' % k)
        I('ld [y,x], ac')
        I('xor 0x%02X, ac' % ch)
        I('bne %s' % fail)


def _leave(I, L, prefix):
    L(prefix + '_esc')
    I('ld %d, ac' % WHY_ESC)
    I('bra %s_go' % prefix)
    L(prefix + '_next')
    I('ld %d, ac' % WHY_NEXT)
    L(prefix + '_go')
    I('ld 0x%02X, y' % (MENU_BLK >> 8))
    I('ld 0x%02X, x' % MB_WHY)
    I('ld ac, [y,x]')
    I('jmp 0x%02X' % MB_EXIT, 'the menu\'s exit code (RAM x5D20)')


def hook_blocks(ret, reth):
    out = []

    items = []
    I = lambda t, c='': items.append(('I', t + ('    ; ' + c if c else '')))
    L = lambda t: items.append(('L', t))
    L('hk_poll')
    _magic(I, 'hkp_ret')
    I('ld 0x50, y', 'line read (V9:V2)')
    I('ld [y,x], ac')
    I('ld 0x%02X, y' % (MENU_BLK >> 8))
    I('ld 0x%02X, x' % MB_CUR)
    I('ld ac, [y,x]')
    I('ld 0x%02X, x' % MB_LAST)
    I('sub [y,x], ac', 'cur - last - 96 >= 0: a new frame')
    I('sub 96, ac')
    I('ld 0x%02X, x' % MB_CUR)
    I('blt hkp_same')
    I('ld [y,x], ac')
    I('ld 0x%02X, x' % MB_LAST)
    I('ld ac, [y,x]')
    I('ld 0x%02X, y' % PORT, 'Esc: key column 0, row 0')
    I('ld 0x00, x')
    I('ld 0x%02X, [y,x]' % P_COL0)
    for _ in range(4):
        I('nop')
    I('ld [y,x], ac')
    I('ld 0x%02X, [y,x]' % P_IDLE)
    I('and 1, ac')
    I('beq hkp_esc')
    I('ld 0x%02X, y' % (MENU_BLK >> 8))
    I('ld 0x%02X, x' % MB_MODE)
    I('ld [y,x], ac')
    I('bne hkp_ret', 'picked from the menu: no time limit')
    I('ld 0x%02X, x' % MB_LEFT)
    I('ld [y,x], ac')
    I('dec')
    I('ld ac, [y,x]')
    I('bcc hkp_ret', 'no borrow')
    I('ld 0x%02X, x' % (MB_LEFT + 1))
    I('ld [y,x], ac')
    I('dec')
    I('ld ac, [y,x]')
    I('blt hkp_next', 'below 0: time up')
    I('bra hkp_ret')
    L('hkp_same')
    I('ld [y,x], ac')
    I('ld 0x%02X, x' % MB_LAST)
    I('ld ac, [y,x]')
    L('hkp_ret')
    I('ld [0x%02X], y' % reth)
    I('jmp [0x%02X]' % ret)
    _leave(I, L, 'hkp')
    out.append(('hk_poll', items))

    items = []
    I = lambda t, c='': items.append(('I', t + ('    ; ' + c if c else '')))
    L = lambda t: items.append(('L', t))
    L('hk_done')
    _magic(I, 'hkd_ret')
    I('ld 0x%02X, x' % MB_MODE)
    I('ld [y,x], ac')
    I('beq hkd_next', 'rotating: next program')
    L('hkd_ret')
    I('ld [0x%02X], y' % reth)
    I('jmp [0x%02X]' % ret)
    L('hkd_next')
    I('ld %d, ac' % WHY_NEXT)
    I('ld 0x%02X, x' % MB_WHY)
    I('ld ac, [y,x]')
    I('jmp 0x%02X' % MB_EXIT, 'the menu\'s exit code (RAM x5D20)')
    L('hk_hold')
    _magic(I, 'hkd_ret')
    I('ld 0x%02X, x' % MB_MODE)
    I('ld [y,x], ac')
    I('bne hkd_ret', 'picked from the menu: no time limit')
    I('ld 0x%02X, x' % MB_LEFT, 'MB_LEFT - MB_HOLD < 0: leaves sooner anyway')
    I('ld [y,x], ac')
    I('ld 0x%02X, x' % MB_HOLD)
    I('sub [y,x], ac')
    I('ld 0x%02X, x' % (MB_LEFT + 1))
    I('ld [y,x], ac')
    I('bcc hkd_nb')
    I('sub 1, ac')
    L('hkd_nb')
    I('ld 0x%02X, x' % (MB_HOLD + 1))
    I('sub [y,x], ac')
    I('blt hkd_ret')
    I('ld 0x%02X, x' % MB_HOLD, 'MB_LEFT = MB_HOLD')
    I('ld [y,x], ac')
    I('ld 0x%02X, x' % MB_LEFT)
    I('ld ac, [y,x]')
    I('ld 0x%02X, x' % (MB_HOLD + 1))
    I('ld [y,x], ac')
    I('ld 0x%02X, x' % (MB_LEFT + 1))
    I('ld ac, [y,x]')
    I('bra hkd_ret')
    out.append(('hk_done', items))
    return out


def as_lines(items):
    """items -> asm lines (labels flush left, instructions indented)"""
    return [t + ':' if k == 'L' else '    ' + t for k, t in items]
