# Project Instructions

## Target device and toolchain
- Device: Atmel ATF22V10C
- Toolchain: WinCUPL 2
- All designs must be customized for the ATF22V10C (pin assignments, macrocell/OLMC usage, product-term limits, and device mnemonic in CUPL headers).

## PLD → VHDL conversion
- Do not optimize the code or equations. Translate them as written.
- Keep individual pins as separate ports/signals. Do not aggregate pins into a vector (e.g., no `std_logic_vector`).
- Entity names must be all lowercase.
- The VHDL filename must be all lowercase and match the entity name (e.g., entity `addrdecode` → `addrdecode.vhd`).

## VHDL naming
- Signals use lowerCamelCase (e.g., `chipSelect`, `addrValid`, `writeEnable`).

## File updates
- When you update a file that has a date field (e.g., the `Date` line in a CUPL header, or a "Generated"/"Date" line in a VHDL comment header), set it to the current date.

## Git workflow
- When a task needs a new branch, number branches sequentially (e.g., `branch-001`, `branch-002`, ...). Check existing branches first to find the next number.
- If the changes on that branch have no issues, merge it back into the main branch and delete the branch.
