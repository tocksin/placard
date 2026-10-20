# Selling the Placard as a kit

Date: 2026-10-20

Who can buy the parts, program the chips, bag each kit and ship it, so
that no one has to hand-pack every kit.  Researched 2026-10-20 from public
web pages.  None of these services publish prices for small jobs, so the
costs below are rough estimates (marked *est.*) to check against a real
quote.

## What has to be programmed

Each kit needs 21 programmed chips, from 16 different images:

| Chips | Part | Images | Per kit |
|---|---|---|--:|
| Main board PLDs | ATF22V10C-7PX | State, Branch, ALU (x2), Address mux (x4), Memory control, I/O decode, Sync, Audio slot, Port | 13 |
| Main board PLDs | ATF22V10C-10PU | PC counter (x2), H counter, V counter, Color decoder | 5 |
| Cartridge PLD | ATF22V10C-10PU | Cartridge loader | 1 |
| Cartridge EEPROMs | AT28C256-15PU | ROM low, ROM high | 2 |

That is 14 PLD JEDEC files (`src/pld`, 19 chips) and 2 EEPROM binaries.
The same image goes into both ALU chips, both PC chips and all four
address mux chips.

Two things matter more for a kit than for a single build:

- **Labels.**  Nineteen programmed 22V10s look the same.  Every chip
  needs a label with its job and revision (for example "MUX r03"), or a
  builder will swap the State and Sync PLDs.  Programming services
  offer labeling or ink dots; doing it yourself means a sheet of small
  printed labels.
- **Frozen revisions.**  A programming service charges a setup for each
  image, so every PLD change after the first order is another setup.
  Program kits only after the prototype has passed bring-up.

The rest of the kit is ordinary stock: 7 SN74F377AN, 4 SN74F541N, 2
AS7C256C-15PCN (4 with the cartridge's), a CD74ACT273E, SN74AC32N,
SN74HCT574N, SN74HC574N, the 3.3 V regulator and oscillator (not chosen
yet), sockets, passives, connectors, two PCBs and the case.  The passive
and connector BOM comes out of the KiCad project (SCHEMATIC_PLAN.md) once
the schematic is done.

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
  one place.**  Prices are quoted per job.  Check that the -10PU and the
  AT28C256-15PU are also marked "Verified" on their product pages.
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

## Options

| Plan | Who programs | Who bags | Who ships | Up-front cost | Your time per kit |
|---|---|---|---|---|---|
| A. Do it yourself | You (T48, ~$90) | You | You (Tindie) | Parts only | 30-60 min |
| B. Program yourself, outsource the rest | You | Contract kitter | Crowd Supply | Parts + kitting | 10-15 min |
| C. Digi-Key programs and prepacks the chips | Digi-Key | Digi-Key (chips), kitter (PCB, passives, case) | Crowd Supply | +$1,000-4,000 setup | None |
| D. Digi-Key programs, kitter does all packing | Digi-Key, shipped to the kitter | Contract kitter | Crowd Supply | Setup + kitting | None |

For Plan A and B the XGecu T48 programmer (about $90) programs the
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
3. Either way, before asking for quotes: finish the passive and connector
   BOM from the KiCad project, pick the oscillator and regulator, and
   write a one-page chip label list (part, image, revision, socket).

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
