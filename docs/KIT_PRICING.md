# Kit pricing and selling platforms

Date: 2026-10-25

What a PLACARD kit costs to make at a few batch sizes, what Crowd Supply,
Kickstarter and Tindie take, and a suggested price.  Component costs come
from [BOM.md](BOM.md) (single-unit Mouser/Digi-Key prices, 2026-10-22);
the case from the project's case cost estimate; programming and kitting
from [KITTING.md](KITTING.md).  **No quotes were requested.**  Everything
marked *est.* is a planning number, good to roughly +/- 25 % (case and
PCB lines +/- 50 %), to replace with real quotes before a campaign goal is
set.  Platform fees were read from the platforms' own pages on 2026-10-23.


> **2026-10-25: the Cherry MX keyboard board was dropped** (CHIPS.md,
> IO.md).  PLACARD now uses a PS/2 keyboard only, so the keyboard kit, the
> main board header J1 and the case's switch plate below no longer exist, and
> the main board gained the PS/2 receiver PLD U42 (single-unit parts now
> $184.77, BOM.md).  The products become the core kit, the case (with a
> keyboard blank or a different front) and the PS/2 keyboard / starter pack
> options; the numbers below are kept as written on 2026-10-23 until the
> case is redesigned and the kits re-costed.

## What is sold

Three products, so a buyer with a PS/2 keyboard isn't forced to pay for the
Cherry MX keyboard, which is the most expensive board:

| Product | Contents |
|---|---|
| **Core kit** | Main board PCB and parts (no keyboard header J1, no expansion sockets J9-J12), 64K cartridge PCB and parts, 21 blank chips (19 main PLDs, cartridge PLD, 2 EEPROMs) that the builder programs from the repository's JEDEC files and ROM images (KITTING.md plan E), a label sheet and a printed chip / image / socket table, sockets.  Uses a PS/2 keyboard on J5. |
| **Keyboard kit** (add-on) | Keyboard PCB, 63 Cherry MX switches, LEDs, diodes, resistors, keycaps, stabilisers, ribbon cable, plus main board header J1 |
| **Complete kit** | Core kit + keyboard kit + case (laser-cut acrylic sandwich with switch plate) |
| **Programmer** (option) | XGecu T48 for builders without one; programs the ATF22V10C and AT28C256 |
| **Budget programmer** (option) | XGecu TL866II Plus, the older and cheaper model; same chips, same software |
| **SNES controllers** (option) | Wired SNES-style pads (third-party reproductions) for J2 and J3, sold singly or as a pair |
| **PS/2 keyboard** (option) | Native PS/2 compact keyboard (Perixx PERIBOARD-409P class) for buyers of the core kit without the Cherry MX keyboard |
| **PS/2 mouse** (option) | Native PS/2 optical mouse (Perixx PERIMICE-209P class) for J5's top socket |
| **Starter pack** (option) | PS/2 keyboard + PS/2 mouse + two SNES controllers |
| **USB-C power supply** (option) | 5 V 3 A USB-C charger (20 W USB PD, North American plug) and a 1 m USB-C to USB-C cable for J13; builders with a phone or laptop charger don't need it (BOM.md: CUI SWI20C-T-N + StarTech USB2CC1MNC as the reference parts) |
| **SD card** (option) | Full-size 8-16 GB SDHC card for J4, formatted FAT32 and preloaded with the programs, demos and games; the same image is a free download for builders using their own card |

No kit ships programmed chips (Justin, 2026-10-23): the builder programs
them, so a PLD fix reaches existing owners as a file, not new chips.

Expansion slot sockets ($4.50 each, est.) are best sold as a cheap add-on or
included with the first expansion card, not in the core kit.

## Cost per kit

### Assumptions (all *est.*)

| Line | 50 kits | 100 | 250 | 500 | Basis |
|---|--:|--:|--:|--:|---|
| Component price vs. BOM.md single-unit price: main / cart / keyboard | 88 / 90 / 85 % | 82 / 85 / 78 % | 77 / 80 / 72 % | 73 / 76 / 67 % | Distributor breaks on PLDs, SRAMs, sockets, passives; keyboard falls fastest (switches and keycaps bought in bulk from Cherry/keyboard suppliers) |
| Spares and dead-on-arrival allowance | 3 % of parts | 3 % | 3 % | 3 % | Replacement chips for support |
| Main PCB, 290 x 290 mm, 4-layer, 1.6 mm, HASL lead-free | $16 | $12 | $9.50 | $8 | JLCPCB/PCBWay typical pricing for a board this large (no "$2 for 5" offer above 100 x 100 mm) |
| Cartridge PCB, 39 x 101.5 mm, 2-layer, ENIG, hard-gold bevelled fingers | $4 | $3 | $2.20 | $1.80 | Gold fingers and bevel are the costly options |
| Keyboard PCB, ~290 x 102 mm, 2-layer | $6 | $4.50 | $3.50 | $3 | |
| Case, acrylic sandwich + switch plate, for the 290 x 290 main board + keyboard | $45 | $38 | $30 | $25 | Case cost estimate scaled for the larger board (it assumed 140 mm deep) |
| US tariff on China-made PCBs and case | 35 % | 35 % | 35 % | 35 % | Changes often; 30-50 % range |
| Label sheet and printed chip table (chips ship blank) | $0.50 | $0.50 | $0.50 | $0.50 | No programming cost: the builder programs |
| Contract kitting (count, bag, box) | $8 | $6 | $5 | $4 | Technotronix-style kitter |
| Packaging: retail box, ESD bags, IC foam, printed quick-start card | $9 | $8 | $7 | $6 | Complete kit; core kit $2 less, keyboard kit $3 less |
| Inbound freight (parts to kitter, kits to Crowd Supply) | $3 | $3 | $3 | $3 | Complete kit; core $2, keyboard $1.50 |

Mouser postage to the buyer is not in the cost: Crowd Supply charges it at
checkout.

### Results

| Product | 50 kits | 100 | 250 | 500 |
|---|--:|--:|--:|--:|
| Core kit | $253 | $229 | $211 | $197 |
| Keyboard kit | $149 | $134 | $122 | $112 |
| **Complete kit** | **$453** | **$408** | **$368** | **$339** |

Breakdown of the complete kit:

| Line | 50 | 100 | 250 | 500 |
|---|--:|--:|--:|--:|
| Components (all three boards) | $327 | $303 | $283 | $267 |
| Spares allowance | $10 | $9 | $8 | $8 |
| PCBs (3) | $26 | $20 | $15 | $13 |
| Case | $45 | $38 | $30 | $25 |
| Tariff on PCBs and case | $25 | $20 | $16 | $13 |
| Labels and chip table | $0.50 | $0.50 | $0.50 | $0.50 |
| Kitting | $8 | $6 | $5 | $4 |
| Packaging | $9 | $8 | $7 | $6 |
| Freight in | $3 | $3 | $3 | $3 |
| **Total** | **$453** | **$408** | **$368** | **$339** |

This is higher than the $300-350 guessed in the kit price comparison,
because the main board grew to 290 x 290 mm (bigger PCB and case) and
tariffs, spares, kitting and packaging are now counted.  Components are
still three quarters of the cost, and the keyboard alone is a third.

### PCB fab at a few quantities (per board, *est.*)

| Board | 5 (prototype) | 50 | 100 | 250 | 500 |
|---|--:|--:|--:|--:|--:|
| Main, 4-layer 290 x 290 mm | $30-45 | $14-18 | $10-14 | $8-11 | $7-9 |
| Cartridge, 2-layer, ENIG + gold fingers | $8-14 | $3.5-5 | $2.5-3.5 | $2-2.5 | $1.5-2 |
| Keyboard, 2-layer 290 x 102 mm | $6-10 | $5-7 | $4-5 | $3-4 | $2.5-3.5 |

Plus shipping from China (about $25-60 per order by DHL) and the tariff.
Worth pulling a real quote from JLCPCB's and PCBWay's calculators with the
final Gerbers: the main board's size puts it in a price band where the two
houses can differ by 2x.

### One-off costs to recover (*est.*)

| Item | Cost |
|---|--:|
| Two more prototype PCB rounds (3 boards each, 5 of each) | $400-600 |
| Prototype parts for 3-5 machines, samples for Crowd Supply photos/review | $1,000-2,000 |
| Programmer (XGecu T48) and test fixtures | $100-300 |
| Photos and campaign video | $0-1,500 |
| EMC pre-scan at a test lab (only if selling assembled units or into the EU/UK; see below) | $1,000-3,000 |
| **Planning figure** | **about $4,000** |

$4,000 is $80 a kit at 50, $40 at 100, $16 at 250 and $8 at 500.

## Platform fees

| | Crowd Supply | Kickstarter | Tindie |
|---|---|---|---|
| Model | Curated crowdfunding, then an ongoing store; Mouser ships | Crowdfunding only; you ship | Marketplace; you ship |
| Platform fee | 5 % of the campaign; optional 10 % on pre-orders after it ends | 5 % of funds raised | 5 % of each order |
| Payment processing | 2.9 % + $0.30 per transaction | 3 % + $0.30 per pledge (pledges of $10 and up) | Stripe fees deducted; rate not published (2.9 % + $0.30 assumed) |
| Funding | All or nothing | All or nothing | None: you buy stock first |
| Fulfilment | Optional, flat fee per item set by size, weight and value (quote only).  You send one bulk shipment to Mouser in Texas; it handles packing, postage, customs paperwork, sales tax and returns | Yours: pack and post every kit or pay a 3PL (*est.* $5-10 a kit plus materials); you also handle sales tax and VAT | Yours, as Kickstarter |
| Extra costs | Curated: they must accept the project | Pledge manager (fees on money collected there), 3-5 % dropped pledges, paid ads usually needed | Payout fees (Wise, bank) |
| Audience | Open hardware buyers; the right crowd for a logic-chip computer | Largest, but general; hardware campaigns there lean on advertising | Small, steady; good after the campaign |
| Payout | Within 10 days of hitting the goal, of the campaign ending, and of shipping all orders (pre-order money) | About 2 weeks after the campaign | Through Tindie's payout system (new in July 2026) |

Fees on one kit at the suggested prices (*est.* fulfilment: Crowd Supply
$16 complete / $10 core / $8 keyboard; a 3PL for Kickstarter and Tindie
$10 / $7 / $6; Kickstarter adds 2 % pledge manager and 4 % dropped pledges):

| Product, price | Crowd Supply campaign | Crowd Supply pre-order | Kickstarter | Tindie |
|---|--:|--:|--:|--:|
| Core kit, $379 | $40 (10.6 %) | $59 (15.6 %) | $60 (15.9 %) | $37 (9.8 %) |
| Keyboard kit, $199 | $24 (12.1 %) | $34 (17.1 %) | $34 (17.2 %) | $22 (11.1 %) |
| Complete kit, $649 | $68 (10.4 %) | $100 (15.4 %) | $101 (15.6 %) | $62 (9.5 %) |

Tindie looks cheapest per kit, but those numbers leave out your time
posting every kit, the sales tax and VAT you collect yourself, and the
inventory you pay for before anyone orders.  Kickstarter also leaves out
those plus advertising.  Crowd Supply's figure is close to everything,
which is why it is the recommended route: it costs about the same as
Tindie and much less than Kickstarter once your own shipping work is
counted.

## Margin at the suggested price (Crowd Supply campaign)

Margin = price - Crowd Supply fees - cost per kit, before the one-off costs.

| Product, price | 50 kits | 100 | 250 | 500 |
|---|--:|--:|--:|--:|
| Core kit, $379 | $86 (23 %) | $109 (29 %) | $128 (34 %) | $142 (37 %) |
| Keyboard kit, $199 | $26 (13 %) | $41 (21 %) | $53 (27 %) | $63 (32 %) |
| Complete kit, $649 | $129 (20 %) | $174 (27 %) | $213 (33 %) | $242 (37 %) |
| Programmer (T48), $109 | $20-25 a unit at any quantity | | | |
| Budget programmer (TL866II Plus), $79 | about $15 a unit at any quantity | | | |
| SNES controller, $15 (pair $25) | about $4.50 ($8 a pair) | | | |
| PS/2 keyboard, $45 | about $5 | | | |
| PS/2 mouse, $19 | about $3 | | | |
| Starter pack, $79 | about $11 | | | |
| USB-C power supply + cable, $19 | about $7 | | | |

Complete kit at other prices:

| Price | 100 kits | 250 kits |
|--:|--:|--:|
| $549 | $82 (15 %) | $121 (22 %) |
| $599 | $128 (21 %) | $167 (28 %) |
| **$649** | **$174 (27 %)** | **$213 (33 %)** |
| $699 | $220 (31 %) | $259 (37 %) |

Core kit at other prices:

| Price | 100 kits | 250 kits |
|--:|--:|--:|
| $329 | $63 (19 %) | $82 (25 %) |
| $349 | $82 (23 %) | $100 (29 %) |
| **$379** | **$109 (29 %)** | **$128 (34 %)** |
| $399 | $128 (32 %) | $146 (37 %) |

## Suggested price

| Product | Price | Compare |
|---|--:|---|
| **Core kit** | **$379** | Ben Eater 8-bit bundle $330 (no video); Commander X16 full kit $260 (no case, no keyboard) |
| **Keyboard kit** (add-on) | **$199** | A Cherry MX 60 % keyboard kit with keycaps sells for $120-200 |
| **Complete kit** | **$649** ($28 less than the three parts bought separately with a $99 case) | Foenix F256K2 $595 assembled; MEGA65 ~$750 |
| Case on its own | $99 | Mostly for core kit buyers who add the keyboard later; print files free |
| SD card (option) | $15 | An 8-16 GB SDHC card bought in bulk is $3-5; with about $1 for preloading (a duplicator or the kitter), a label and case, and 35 % tariff it costs about $7 landed, leaving about $5-6 after fees if it ships in the kit's box (no extra fulfilment item) |
| Programmer (option) | $109 | XGecu T48 retails at $60-90; at about $62 bought in bulk plus 35 % tariff it costs about $84 landed, leaving $20-25 after fees |
| Budget programmer (option) | $79 | XGecu TL866II Plus retails at $35-50; at about $38 in bulk plus tariff it costs about $51 landed, leaving about $15 after fees.  Older and slower than the T48 and it covers fewer chips, but it programs the ATF22V10C and AT28C256 with the same Xgpro software (or open-source `minipro` on Linux and Mac) |
| SNES controllers (option) | $15 each, $25 a pair | Retail $11 each for wired reproductions (FC Twin, Mars Devices); about $4-5 each bought by the hundred from the factory, about $6 landed with tariff |
| PS/2 keyboard (option) | $45 | Perixx PERIBOARD-409P retails at $35-50 (Commander X16 sells it at $35); about $22 wholesale, $30 landed |
| PS/2 mouse (option) | $19 | Perixx optical PS/2 mouse retails at $15 (TexElec); about $8 wholesale, $11 landed |
| Starter pack (option) | $79 | Keyboard, mouse and two pads ($104 bought separately); about $53 landed |
| USB-C power supply (option) | $19 | The reference pair (CUI SWI20C-T-N + StarTech USB2CC1MNC) is $25 one-off at Mouser; a generic 20 W PD charger and 3 A cable bought by the hundred are about $5-7 and $1-2, about $10 landed with tariff, leaving about $7 after fees.  It must offer 5 V at 3 A on its CC line, as every USB PD charger does, because J13 only has 5.1k CC pull-downs (Justin, 2026-10-25) |

Why these numbers:

- **At 100 kits they give 27-29 % margin on the core and complete kits,**
  which is about $10,900 for 100 core kits ($6,900 after the $4,000 of
  one-off costs) or $17,400 for 100 complete kits ($13,400 after).  That is thin for hardware (Crowd Supply guides and
  small hardware sellers usually aim for 40-50 % so a distributor can
  take a cut later), but a logic-chip kit is a niche product and a
  higher price hurts more than a thin margin at this volume.
- **The keyboard is the weak product.**  At $199 it makes $41 a kit at
  100, half what the core kit makes.  Cheaper keycaps (bulk blank
  or doubleshot sets at $15-20 instead of $38) and switches bought by the
  thousand from Cherry would add about $25 a kit of margin; that is the
  first place to look for savings.
- **Set the campaign goal at about 100 complete-kit equivalents**
  (about $50,000-60,000).  Below 100 the parts don't reach their price
  breaks and the one-off costs eat most of the margin; 50 kits at these
  prices is roughly break-even after the one-off costs.
- **Selling through Mouser after the campaign** (Crowd Supply's
  wholesale arrangement is negotiated) does not fit these margins.  Keep
  later sales on Crowd Supply pre-orders (10 % fee) or Tindie.

### Controller, keyboard and mouse notes

These are conveniences for buyers, not profit lines: each makes $3-11 after
fees, and Crowd Supply's fulfilment fee is per item, so selling them in the
same order as a kit keeps that fee small.  Two things to check before
buying stock:

- **Native PS/2 only.**  The keyboard and mouse must speak PS/2 themselves.
  Most USB mice and keyboards do not work through a passive USB-to-PS/2
  adapter, so a cheap USB mouse with an adapter is not a substitute.
- **Test the chosen models** with the PLACARD keyboard and mouse drivers
  (scan code set 2 keyboard, standard 3-byte mouse packets) and with the
  SNES pad driver.  Reproduction SNES pads vary; buy samples from two
  suppliers first.

Because these parts are made in China, the 35 % tariff is already in the
landed costs above.  If Crowd Supply allows it, the starter pack is the
simplest way to offer all three.

### SD card notes

The SD driver (`sd_init`, IO.md) takes SDSC, SDHC and SDXC cards, but the
file system code reads FAT16 and FAT32 only.  Cards over 32 GB (SDXC)
come formatted exFAT, and the computer only reads the card (new files are
copied on from a PC), so the option should be an 8-16 GB SDHC card, which
is FAT32 as sold; a builder using their own larger card must reformat it
as FAT32.  Small cards are being dropped by the big brands, so pick a
supplier that will keep selling one part number (industrial or
bulk-pack cards), and make one master image to copy.

## Things that move the numbers most

1. **The keyboard parts** (switches $78, keycaps $38 of its $146): see
   above.
2. **Tariffs** on China-made PCBs and the case (35 % assumed): a US PCB
   house costs more than the tariff saves for a 290 x 290 mm 4-layer
   board, but check at quote time.
3. **The main board size**: the 290 x 290 mm 4-layer board is about $12
   at 100 plus tariff.  Not worth shrinking for cost alone.
4. **Builder programming**: blank chips remove all programming cost and
   setup fees, but two things must be done before launch.  Confirm on a
   test chip that the T48 and TL866II Plus really program and verify the
   ATF22V10C-7PX (both list it; not yet tried), and write a programming
   guide with a verify step for each chip, since mixed-up PLDs will be
   the most common support question.  Budget some spare programmed chip
   sets to send to builders who get stuck.
5. **Compliance**: unassembled kits are generally outside FCC equipment
   authorization (the rules cover marketing finished devices; see the
   CommLawBlog source), so a kit-only campaign needs no FCC test.  Selling
   assembled units would, and the EU/UK CE and UKCA rules are stricter
   about kits.  Ask Crowd Supply what it needs for kits shipped
   internationally before deciding whether to budget the EMC pre-scan.

## Next steps

- Upload the final Gerbers to JLCPCB and PCBWay for real 50/100/250 PCB
  quotes, and one case model to SendCutSend/Ponoko.
- Ask Technotronix (or another kitter) to quote kitting 100 kits.
- Contact Crowd Supply with this breakdown: they quote the fulfilment fee
  per product and comment on the price before a campaign is accepted.

## Sources

- Crowd Supply fees: <https://www.crowdsupply.com/working-with-crowd-supply>
- Crowd Supply fulfilment: <https://www.crowdsupply.com/guide/fulfillment-and-logistics>
- Crowd Supply shipping to buyers: <https://crowdsupply.com/guide/ordering-paying-shipping-details>
- Kickstarter fees (LaunchBoom, June 2025): <https://www.launchboom.com/crowdfunding-tips/how-much-does-kickstarter-charge/>
- Kickstarter fee guide (PledgeBox): <https://www.pledgebox.com/post/how-much-does-kickstarter-take>
- Tindie terms, section 9 Fees (effective 2026-06-30): <https://www.tindie.com/about/terms/>
- Tindie new payment and payout system (2026-07-01): <https://discuss.tindie.com/t/important-update-tindie-s-new-payment-and-seller-payout-system-is-now-live/567249>
- FCC and kits: <https://www.commlawblog.com/2007/11/articles/enforcement-activities-fines-forfeitures-etc/some-assembly-required/>
