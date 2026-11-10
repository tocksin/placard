# Pin-swap suggestions

Board `../r1.kicad_pcb`. Model cost 45291 -> 44822, expected vias 509 -> 499, MST length 36.92 -> 36.69 m (30 greedy steps).

Suggestions only: each change needs the schematic (and for a PLD its PIN lines) changed and rechecked.

41 pins change on 7 parts.

| part | pin | was | now |
|---|---|---|---|
| U10 | 8 | PC6 | PC14 |
| U10 | 13 | PC7 | Y6 |
| U10 | 14 | Y6 | PC7 |
| U10 | 16 | PC14 | PC6 |
| U7 | 7 | VA0 | Y1 |
| U7 | 11 | VA1 | PC1 |
| U7 | 13 | PC1 | PC9 |
| U7 | 14 | Y0 | PC8 |
| U7 | 15 | VA8 | VA0 |
| U7 | 16 | PC8 | VA1 |
| U7 | 17 | Y1 | VA8 |
| U7 | 19 | PC9 | Y0 |
| U3 | 15 | PC0 | PC5 |
| U3 | 17 | PC5 | PC7 |
| U3 | 18 | PC7 | PC6 |
| U3 | 19 | PC6 | PC2 |
| U3 | 20 | PC4 | Net-(U3-CO) |
| U3 | 21 | PC2 | PC4 |
| U3 | 23 | Net-(U3-CO) | PC0 |
| U9 | 8 | PC4 | PC13 |
| U9 | 13 | PC5 | Y5 |
| U9 | 17 | Y5 | PC5 |
| U9 | 19 | PC13 | PC4 |
| U4 | 7 | Y5 | Net-(U3-CO) |
| U4 | 8 | Y6 | LOAD_PC_HIGH |
| U4 | 10 | LOAD_PC_HIGH | Y6 |
| U4 | 13 | Net-(U3-CO) | Y5 |
| U4 | 15 | PC8 | PC12 |
| U4 | 16 | PC11 | PC14 |
| U4 | 19 | PC14 | unconnected-(U4-CO-Pad23) |
| U4 | 20 | PC12 | PC10 |
| U4 | 21 | PC10 | PC11 |
| U4 | 23 | unconnected-(U4-CO-Pad23) | PC8 |
| U2 | 14 | COUT | unconnected-(U2-ALU_DONE-Pad18) |
| U2 | 18 | unconnected-(U2-ALU_DONE-Pad18) | LOAD_PC_HIGH |
| U2 | 22 | LOAD_PC_HIGH | COUT |
| U8 | 8 | PC2 | Y3 |
| U8 | 13 | PC3 | PC10 |
| U8 | 16 | PC10 | PC3 |
| U8 | 17 | Y3 | PC11 |
| U8 | 19 | PC11 | PC2 |
