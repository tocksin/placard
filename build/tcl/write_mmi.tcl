# write_mmi.tcl
#
# write_mmi <mmiFile> <depth> <width>
#
# Writes a memory map (MMI) file for updatemem, describing every block RAM in
# the open implemented design.  Run it with the routed design open
# (open_run impl_1).  Vivado's write_mem_info only covers processor memories,
# so this builds the map from the properties Vivado puts on each inferred
# block RAM cell: LOC, and the address range and data bits it holds
# (bram_addr_begin/end and bram_slice_begin/end, or ram_* in newer versions).
#
# Each memory instance (hierarchy above the block RAM cells, e.g. ramComp)
# becomes one <Processor> in the MMI, named by that instance path; pass that
# name to updatemem with -proc.  Every instance must cover all depth x width
# bits exactly once, otherwise the map is refused: synthesis can trim the
# parts of a read-only memory that hold constant data, and those parts cannot
# be changed without a full build.
#
# Returns the list of instance names.
#
# Date: 10/16/2026

proc write_mmi {mmiFile depth width} {
    set cells [get_cells -hierarchical -quiet -filter {PRIMITIVE_TYPE =~ BMEM.*.*}]
    if {[llength $cells] == 0} {
        error "write_mmi: no block RAM cells found (is the implemented design open?)"
    }
    set propSets {
        {bram_addr_begin bram_addr_end bram_slice_begin bram_slice_end}
        {ram_addr_begin  ram_addr_end  ram_slice_begin  ram_slice_end}
    }

    # lanes(inst) = list of {addrBegin addrEnd lsb msb memType placement}
    array set lanes {}
    foreach cell $cells {
        set cellProps [string tolower [list_property $cell]]
        set names {}
        foreach propSet $propSets {
            if {[lsearch -exact $cellProps [lindex $propSet 0]] >= 0} {
                set names $propSet
                break
            }
        }
        if {$names eq ""} {
            error "write_mmi: $cell has no bram_addr_begin or ram_addr_begin property"
        }
        set vals {}
        foreach n $names {
            lappend vals [get_property $n $cell]
        }
        lassign $vals addrBegin addrEnd sliceBegin sliceEnd

        set loc [get_property LOC $cell]
        if {![regexp {^(RAMB18|RAMB36)_(X\d+Y\d+)$} $loc -> memType placement]} {
            error "write_mmi: $cell has unexpected LOC '$loc'"
        }
        # updatemem names block RAMs by their data capacity, without parity:
        # RAMB36 -> RAMB32, RAMB18 -> RAMB16 (Placement keeps the LOC X/Y)
        set memType [dict get {RAMB36 RAMB32 RAMB18 RAMB16} $memType]
        set name  [get_property NAME $cell]
        set slash [string last / $name]
        if {$slash < 0} {
            set inst top
        } else {
            set inst [string range $name 0 [expr {$slash - 1}]]
        }
        lappend lanes($inst) [list $addrBegin $addrEnd $sliceBegin $sliceEnd \
                                   $memType $placement]
    }

    # every bit of every address must be held by exactly one block RAM
    foreach inst [lsort [array names lanes]] {
        for {set bit 0} {$bit < $width} {incr bit} {
            set ranges {}
            foreach lane $lanes($inst) {
                lassign $lane aBegin aEnd lsb msb
                if {$bit >= $lsb && $bit <= $msb} {
                    lappend ranges [list $aBegin $aEnd]
                }
            }
            set next 0
            foreach r [lsort -integer -index 0 $ranges] {
                lassign $r aBegin aEnd
                if {$aBegin != $next} {
                    error "write_mmi: $inst data bit $bit is not stored in block RAM\
                           at address [format %04X $next] (trimmed or overlapping);\
                           do a full build instead"
                }
                set next [expr {$aEnd + 1}]
            }
            if {$next != $depth} {
                error "write_mmi: $inst data bit $bit is not stored in block RAM\
                       at address [format %04X $next] (trimmed); do a full build instead"
            }
        }
    }

    set fh [open $mmiFile w]
    puts $fh {<?xml version="1.0" encoding="UTF-8"?>}
    puts $fh {<MemInfo Version="1" Minor="0">}
    foreach inst [lsort [array names lanes]] {
        puts $fh "  <Processor Endianness=\"Little\" InstPath=\"$inst\">"
        puts $fh "    <AddressSpace Name=\"$inst\" Begin=\"0\" End=\"[expr {$depth - 1}]\">"
        # one BusBlock per address range, bit lanes LSB first
        array unset blocks
        array set blocks {}
        foreach lane $lanes($inst) {
            lappend blocks([lindex $lane 0]) $lane
        }
        foreach aBegin [lsort -integer [array names blocks]] {
            puts $fh "      <BusBlock>"
            foreach lane [lsort -integer -index 2 $blocks($aBegin)] {
                lassign $lane aBegin aEnd lsb msb memType placement
                puts $fh "        <BitLane MemType=\"$memType\" Placement=\"$placement\">"
                puts $fh "          <DataWidth MSB=\"$msb\" LSB=\"$lsb\"/>"
                puts $fh "          <AddressRange Begin=\"$aBegin\" End=\"$aEnd\"/>"
                puts $fh "          <Parity ON=\"false\" NumBits=\"0\"/>"
                puts $fh "        </BitLane>"
            }
            puts $fh "      </BusBlock>"
        }
        puts $fh "    </AddressSpace>"
        puts $fh "  </Processor>"
    }
    puts $fh "  <Config>"
    puts $fh "    <Option Name=\"Part\" Val=\"[get_property PART [current_design]]\"/>"
    puts $fh "  </Config>"
    puts $fh "</MemInfo>"
    close $fh
    puts "write_mmi: wrote $mmiFile ([join [lsort [array names lanes]] {, }])"
    return [lsort [array names lanes]]
}
