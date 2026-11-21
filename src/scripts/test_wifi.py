#!/usr/bin/env python3
"""
test_wifi.py - run WIFI.PLC (wifi.masm) with the WiFi card model
(io_devices.WifiCard, docs/architecture/WIFICARD.md) in placard_sim

    python3 test_wifi.py

Builds the 32K ROM and a card holding DOS.PLC and WIFI.PLC, boots it
(test_dos.Rig) and puts a WiFi card in a slot:
  1. card in slot 3: the program finds it and shows the module's name
  2. a name and password typed: the join, the address, the time
  3. Enter at the web site: example.com's page comes back through OPEN,
     SEND and RECV and is printed
  4. Esc brings the DOS's browser back
  5. card in slot 2, Enter at the name: the network the module kept; a
     site typed
  6. a wrong password: the message
  7. a program that left a reply unread: the next request still works
  8. no card: the message

Date: 11/21/2026
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import placard_sim as ps      # noqa: E402
import io_devices as iod      # noqa: E402
import gen_plc                # noqa: E402
import test_dos               # noqa: E402

PAGE = (b'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n'
        + b''.join(b'Line %d of the page from the model.\n' % i for i in range(1, 13)))
CLOCK = (26, 11, 21, 18, 54, 7, 6)


def site(name):
    def f(sent):
        want = b'GET / HTTP/1.0\r\nHost: ' + name + b'\r\nConnection: close\r\n\r\n'
        return PAGE if sent == want else b''
    return f


def new_card(**kw):
    return iod.WifiCard(networks={'home': 'secret12'},
                        hosts={('example.com', 80, False): site(b'example.com'),
                               ('placard.test', 80, False): site(b'placard.test')},
                        clock=CLOCK, **kw)


def start(plc, slot, card):
    r = test_dos.boot_plc('WIFI.PLC', plc, 0x0100)
    if r is None:
        return None
    r.cpu.slots = iod.Slots()
    if card is not None:
        r.cpu.slots.cards[slot - 1] = card
    return r


def wait_text(r, text, frames, what):
    for _ in range(frames // 5):
        r.run(5)
        if r.find_row(text, 0, 60) is not None:
            return True
    r.fail('%s: "%s" is not on the screen' % (what, text))
    for row in r.rows(0, 12):
        print('   |' + row)
    return False


def main():
    prog, psyms, _ = ps.assemble(open(os.path.join(HERE, 'wifi.asm')).read(), HERE)
    lib = test_dos.build()[3]
    plc = gen_plc.make(prog, psyms, lib)[0]
    if plc != open(os.path.join(HERE, '..', '..', 'sdcard', 'WIFI.PLC'), 'rb').read():
        print('FAIL: sdcard/WIFI.PLC is not wifi.asm (run gen_plc.py)')
        return 1
    ok = True

    print('1. card in slot 3')
    card = new_card()
    r = start(plc, 3, card)
    wait_text(r, 'Network name', 60, 'the card found')
    for row in r.rows(1, 6):
        print('   |' + row)
    if r.find_row('WiFi card in slot 3', 0, 10) is None or r.find_row('Module: PLACARD WIFI 1.0', 0, 10) is None:
        r.fail('the slot or the module name')

    print('2. the join')
    r.type('home\n')
    wait_text(r, 'Password', 30, 'the password question')
    r.type('secret12\n')
    wait_text(r, 'Web site', 300, 'the join')
    for row in r.rows(4, 10):
        print('   |' + row)
    if r.find_row('Joined.  Address 192.168.1.77', 0, 12) is None:
        r.fail('the address')
    if r.find_row('Time (UTC) 2026-11-21 18:54:07', 0, 12) is None:
        r.fail('the time')
    if card.saved != ('home', 'secret12'):
        r.fail('the module kept %r' % (card.saved,))

    print('3. the page')
    r.type('\n')
    wait_text(r, 'The site closed', 600, 'the page')
    rows = [x for x in r.rows(0, 60) if x.strip()]
    for row in rows[-17:]:
        print('   |' + row)
    for line in PAGE.replace(b'\r', b'').split(b'\n'):
        if line and r.find_row(line.decode(), 0, 60) is None:
            r.fail('line missing: %r' % line)
            break
    if card.log[-1][0] != 0x13:
        r.fail('no CLOSE')
    if card.latch != 0x0F:
        r.fail('the register is left at %02X' % card.latch)
    print('   %d requests' % len(card.log))

    print('4. Esc')
    if not test_dos.esc_to_dos(r):
        r.fail('Esc')
    ok &= r.ok

    print('5. card in slot 2, the kept network, a site typed')
    card = new_card(saved=('home', 'secret12'))
    r = start(plc, 2, card)
    wait_text(r, 'Network name', 60, 'the card found')
    if r.find_row('WiFi card in slot 2', 0, 10) is None:
        r.fail('the slot')
    r.type('\n')
    wait_text(r, 'Web site', 300, 'the join')
    r.type('placard.test\n')
    wait_text(r, 'The site closed', 600, 'the page')
    if r.find_row('Line 12 of the page from the model.', 0, 60) is None:
        r.fail('the page')
    ok &= r.ok

    print('6. a wrong password, and no network kept')
    r = start(plc, 4, new_card())
    wait_text(r, 'Network name', 60, 'the card found')
    r.type('home\n')
    wait_text(r, 'Password', 30, 'the password question')
    r.type('wrong\n')
    wait_text(r, 'Could not join', 300, 'the message')
    ok &= r.ok
    r = start(plc, 1, new_card())
    wait_text(r, 'Network name', 60, 'the card found')
    r.type('\n')
    wait_text(r, 'no network kept', 60, 'the message')
    ok &= r.ok

    print('7. a reply left unread')
    card = new_card()
    card.wait = 0
    card.reply = [0x41, 0, 3, 1, 2, 3]
    r = start(plc, 1, card)
    wait_text(r, 'Network name', 60, 'the card found')
    if r.find_row('Module: PLACARD WIFI 1.0', 0, 10) is None:
        r.fail('the module name after a stale reply')
    ok &= r.ok

    print('8. no card; a memory card is not a WiFi card')
    r = start(plc, 1, None)
    wait_text(r, 'There is no WiFi card', 60, 'the message')
    ok &= r.ok
    r = start(plc, 2, iod.MemoryCard())
    wait_text(r, 'There is no WiFi card', 60, 'the message')
    ok &= r.ok

    print('ok' if ok else 'FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
