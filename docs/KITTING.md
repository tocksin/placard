# Selling the Placard as a kit

Date: 2026-10-28

Who can buy the parts, program the chips, bag each kit and ship it, so
that no one has to hand-pack every kit.  Researched 2026-10-20 from public
web pages.  None of these services publish prices for small jobs, so the
costs below are rough estimates (marked *est.*) to check against a real
quote.

## What has to be programmed

Each kit needs 22 programmed chips, from 17 different images:

| Chips | Part | Images | Per kit |
|---|---|---|--:|
| Main board PLDs | ATF22V10C-7PX | State, Branch, PC counter (x2), Instruction register, ALU (x2), Address mux (x4), Memory control, I/O decode, H counter, V counter, Sync, Color decoder, Audio slot, Port | 19 |
| Cartridge PLD | ATF22V10C-7PX | Cartridge loader | 1 |
| Cartridge EEPROMs | AT28C256-15PU | ROM low, ROM high | 2 |

That is 15 PLD JEDEC files (`src/pld`, 20 chips) and 2 EEPROM binaries.
The same image goes into both ALU chips, both PC chips and all four
address mux chips.

Two things matter more for a kit than for a single build:

- **Labels.**  Twenty programmed 22V10s look the same.  Every chip
  needs a label with its job and revision (for example "MUX r03"), or a
  builder will swap the State and Sync PLDs.  Programming services
  offer labeling or ink dots; doing it yourself means a sheet of small
  printed labels.
- **Frozen revisions.**  A programming service charges a setup for each
  image, so every PLD change after the first order is another setup.
  Program kits only after the prototype has passed bring-up.
- **The two 377s.**  The five SN74F377AN (U18-U22) and the one
  CD74HCT377E (U23) share a pinout and look alike.  Pack the CD74HCT377E
  in its own bag labeled "U23 only, 74HCT377"; the board's silkscreen
  above each socket says which type goes there.
- **The two diodes.**  The Schottkys are black 1N5817s (DO-41) and the
  small-signal diodes are glass 1N4148s, so they look different on purpose.

The rest of the kit is ordinary stock: 5 SN74F377AN, a CD74HCT377E, 3 SN74F541N, 2
AS7C256C-15PCN (4 with the cartridge's), a CD74ACT273E, a
SN74HCT574N, the 3.3 V regulator and oscillator (not chosen
yet), the power toggle (CIT ANT11TFHQE), the reset relay (CIT J1071CS5VDC.36)
and its button (C&K PTS645VL58-2 LFS), sockets, passives, connectors, two PCBs and the case
(the keyboard is a PS/2 keyboard since 2026-10-25).  The full
bills of materials, one per assembly (main board, each cartridge, case), are indexed in [BOM.md](BOM.md),
written from the KiCad sheets.

## The services

### Distributors that program and pack: Digi-Key, Arrow, Avnet

- **Digi-Key** has a programming center with "100,000+ devices", serial
  numbers, labeling, ink dotting and custom packaging.  Its product page
  for the **ATF22V10C-7PX marks it "DigiKey Programmable: Verified"**
  (Microchip lead time 9 weeks at the time).  Quotes take about 3 days,
  and a first article (up to 10 programmed parts for you to check) ships
  in about 3 business days.  Its custom orders department also does
  "prepacks": several parts bagged together as one kit with its own
  reorderable part number.  So **Digi-Key can, in principle, buy every
  chip, program the 21, label them and bag one chip kit per customer in
  one place.**  Prices are quoted per job.  Check that the
  AT28C256-15PU is also marked "Verified" on their product pages.
- **Arrow** programs "small and large quantities", including parts not
  bought from Arrow (so it can program chips you send it), with a
  24-hour first article and 72-hour production.  It does not kit.
- **Avnet** programs EPROMs, EEPROMs and programmable logic, aimed at
  volume work.  Not a fit below a few thousand parts.
- **Mouser** has no published programming or kitting service.

*Est.* cost: a setup charge of roughly $50 to $250 per image (16 images,
so about $1,000 to $4,000 once) plus roughly $0.50 to $2 per chip
programmed and labeled (about $10 to $40 per kit), plus a kitting charge
per bag.  The setup is the big part for a small run: at 25 kits it is
$40 to $160 a kit, at 200 kits $5 to $20.

### Contract kitters

These buy (or receive) the parts from a BOM, count them into bags with
the PCB and manual, and ship the finished kits to you or to a
fulfillment house.

- **Technotronix** (US) does kitted orders "from a single prototype up
  to a few thousand", sources the parts itself and works from a BOM.
- **Express Packing** and **Lite Fulfillment** (US) do small-batch
  kitting and bundling with no monthly minimum, but are general product
  packers, not electronics specialists: you would send them the parts.
- **PCBWay** (and similar Chinese PCB houses) can buy parts from a BOM
  along with the PCBs, but sells assembly; loose through-hole kits would
  need a special request.

None of these program PLDs, so the programmed chips come from Digi-Key,
Arrow or you.  *Est.* labor: $3 to $10 per kit for counting and bagging
about 40 chips plus passives, more if they also source the parts.

### Selling and shipping: Crowd Supply, Tindie

- **Crowd Supply** (owned by Mouser) runs the campaign and ships every
  order from Mouser's warehouse in Mansfield, Texas.  You send it one
  bulk shipment of finished kits; it handles storage, packing, postage,
  import paperwork, sales tax and returns.  Fees: 5% of the campaign, an
  optional 10% on pre-orders afterwards, and a fulfillment fee quoted per
  product (one 2025 source says about 12% all-in).  Kits have to arrive
  already packed: Crowd Supply does not bag parts.
- **Tindie** is a marketplace only (5% fee).  The seller ships every
  order, either personally or through a fulfillment house.

Per-kit cost, margin, platform fees and a suggested price are in
[KIT_PRICING.md](KIT_PRICING.md).  Chosen 2026-10-23: kits ship blank chips and the
builder programs them (plan E), with a programmer as a sale option.

## Options

| Plan | Who programs | Who bags | Who ships | Up-front cost | Your time per kit |
|---|---|---|---|---|---|
| A. Do it yourself | You (T48, ~$90) | You | You (Tindie) | Parts only | 30-60 min |
| B. Program yourself, outsource the rest | You | Contract kitter | Crowd Supply | Parts + kitting | 10-15 min |
| C. Digi-Key programs and prepacks the chips | Digi-Key | Digi-Key (chips), kitter (PCB, passives, case) | Crowd Supply | +$1,000-4,000 setup | None |
| D. Digi-Key programs, kitter does all packing | Digi-Key, shipped to the kitter | Contract kitter | Crowd Supply | Setup + kitting | None |

| E. Builders program their own chips | The builder (T48 in the kit, or an add-on) | Digi-Key prepack or kitter, all stock parts | Crowd Supply | Parts only | None |

**Plan E, the builder programs.**  The kit ships blank chips plus a
programmer (or the programmer as an optional add-on, since many
retro-computer builders already own a T48 or TL866II).  The JEDEC files
and ROM binaries come from the repository, so a PLD fix reaches existing
owners without new chips, and a builder can reflash the cartridge with
new software.  Every part is then plain stock, so any kitter or a
Digi-Key prepack can bag it with no programming setup at all.  The costs:
the kit price goes up by the programmer (about $60 to $90), the builder
must put the right image into each of 21 chips and label them (the
manual needs a table of chip, image and socket, and a "verify" step), and
a support question about a mixed-up chip is likely.  The board cannot
program its own PLDs, since it needs all of them to run.

Cheap programmers for Plan E (prices are rough retail, lower in bulk):

| Programmer | Price | ATF22V10C | AT28C256 | Notes |
|---|---|---|---|---|
| XGecu TL866II Plus | $35-50 | Listed, test first | Yes | Most common hobby programmer; Windows app, or open-source `minipro` on Linux/Mac |
| XGecu T48 | $60-90 | Listed, test first | Yes | TL866II successor, same software |
| Afterburner (open source, Arduino Uno + small shield with a VPP boost converter) | $15-25 in parts | Yes, written for ATF16V8/22V10 | No | PLDs only |
| A Placard programmer: Arduino Nano, ZIF-24 and ZIF-28 sockets, 2x 74HC595 for the address, VPP boost (Afterburner plus a Ben Eater style EEPROM writer) | $15-25 in parts | Yes | Yes | One more PCB to design; could ship as part of the kit |

For Plan A, B and E the XGecu T48 programmer (about $90) programs the
AT28C256, and its GAL22V10 support should cover the ATF22V10C; confirm
with a test chip before buying 400 of them.  Programming, verifying and
labeling 21 chips takes about 10 to 15 minutes a kit.

## Recommendation

1. **First run (up to about 50 kits): Plan B.**  Program and label the
   chips yourself, which costs no setup fees and lets you change a PLD
   between batches.  Ask Technotronix (or a similar kitter) to quote
   buying the rest of the BOM and bagging it with your programmed chips,
   PCBs and manual, and send the finished kits to Crowd Supply.  About
   10 hours of programming for 50 kits is the only hands-on work.
2. **Larger runs (100+), once the PLDs are frozen: Plan C.**  Ask
   Digi-Key's custom orders department for a quote on the chips
   programmed, labeled and prepacked one bag per kit, shipped to the
   kitter.  This is the closest to one place doing everything; the
   setup fee spreads thin at this volume.
3. **Plan E fits alongside either.**  Sell a blank-chip kit, with the
   programmer as an add-on, for builders who want to program (and later
   update) their own chips, next to the pre-programmed kit.
4. Either way, before asking for quotes: finish the passive and connector
   BOM from the KiCad project, pick the oscillator and regulator, and
   write a one-page chip label list (part, image, revision, socket).

## Bring-up test leads

Every kit includes two test leads, short wires with a clip on one end and
a probe tip on the other (Justin 2026-10-25), one for ground and one for
power.  BRINGUP.md step 6 clips both on before power-up and uses them
to set the color decoder's undriven inputs high or low through a 10k
before the pixel buffer and line code register are in.  No part number
chosen yet (a mini-grabber to test-probe lead, est. $1-3 each at volume); they
are not on the schematic, so they are not in the BOM.

## Add-ons

**USB-C power supply** (option, Justin 2026-10-25; price in
[KIT_PRICING.md](KIT_PRICING.md)): a 5 V 3 A USB-C charger and a 1 m
USB-C to USB-C cable for J13.  It is an accessory, in no BOM; the reference
parts are CUI SWI20C-T-N (20 W USB PD, North American plug) and StarTech
USB2CC1MNC.  For a run, buy a generic 20 W PD charger and 3 A cable by the
hundred instead (about $5-7 and $1-2).  Whatever is bought must offer 5 V
at 3 A on its CC line, because J13 has only 5.1k CC pull-downs; every USB
PD charger does, but check a sample on a board before the bulk order.
They come from a different supplier than the BOM, so the kitter receives
them as their own carton and packs one charger and one cable in the kit's
box for orders that include the option (no extra fulfilment item).  Chargers
need the usual safety marks (UL/ETL for North America); a buyer outside it
needs a charger with their own plug, so offer the option only where the
plug fits or source a multi-plug model.

## Sources

- Digi-Key programming services:
  <https://digikey.com/en/resources/dk-services/programming-services>
- Digi-Key ATF22V10C-7PX product page ("DigiKey Programmable: Verified"):
  <https://www.digikey.com/en/products/detail/microchip-technology/ATF22V10C-7PX/1007479>
- Digi-Key prepacks and custom orders (TechForum):
  <https://forum.digikey.com/t/value-add-services-and-custom-capabilities/6984>
- Arrow device programming: <https://www.arrow.com/device-programming>
- Avnet device programming:
  <https://www.avnet.com/apac/solutions/logistics/value-add-and-integration/device-programming-and-modifications/>
- Technotronix kitting:
  <https://www.technotronix.us/kitted-pcb-assembly-service.html>
- Express Packing: <https://expresspacking.com/kitting-and-assembly-services/>
- Lite Fulfillment: <https://litefulfillment.com/kitting-and-bundling>
- Crowd Supply fees: <https://www.crowdsupply.com/working-with-crowd-supply>;
  shipping: <https://crowdsupply.com/shipping>
- Tindie seller terms: <https://www.tindie.com/about/terms/>
