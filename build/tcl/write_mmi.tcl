# write_mmi.tcl
#
# Helpers for updating the memory contents of a bitstream with updatemem
# (used by update_mem.tcl and build_and_load.tcl).
#
# write_mmi <mmiFile> <depth> <width> <bitOrder>
#
# Writes a memory map (MMI) file for updatemem, describing every block RAM in
# the open implemented design.  Run it with the routed design open
# (open_run impl_1).  Vivado's write_mem_info only covers processor memories,
# so this builds the map from the properties Vivado puts on each inferred
# block RAM cell: LOC, and the address range and data bits it holds
# (bram_addr_begin/end and bram_slice_begin/end, or ram_* in newer versions).
#
# Each memory instance (hierarchy above the block RAM cells: ramComp,
# cartComp/sramComp and cartComp/romComp) becomes one <Processor> in the MMI, named by that instance path;
# pass that name to updatemem with -proc.  Every instance must cover all depth x width
# bits exactly once, otherwise the map is refused: synthesis can trim the
# parts of a read-only memory that hold constant data, and those parts cannot
# be changed without a full build.
#
# bitOrder is how DataWidth bit numbers are written:
#     msbFirst   bit 0 of the MMI word is the most significant data bit
#                (updatemem's numbering; lsbFirst made the first fast builds
#                load every byte bit-reversed)
#     lsbFirst   bit 0 is the least significant data bit
# update_mem.tcl checks which one reproduces the full-build bitstream.
#
# Returns the list of instance names.
#
# Date: 10/21/2026

proc write_mmi {mmiFile depth width bitOrder} {
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
                if {$bitOrder eq "msbFirst"} {
                    set mmiMsb [expr {$width - 1 - $lsb}]
                    set mmiLsb [expr {$width - 1 - $msb}]
                } else {
                    set mmiMsb $msb
                    set mmiLsb $lsb
                }
                puts $fh "          <DataWidth MSB=\"$mmiMsb\" LSB=\"$mmiLsb\"/>"
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
    puts "write_mmi: wrote $mmiFile ($bitOrder) - [join [lsort [array names lanes]] {, }]"
    return [lsort [array names lanes]]
}

# write_update_mem <memFile> <outFile> <depth>
#
# Converts a gen_random_ram.tcl or gen_rom.tcl image (one hex byte per line) to updatemem's
# .mem format: @address followed by 16 data bytes per line.
proc write_update_mem {memFile outFile depth} {
    set fh [open $memFile r]
    set bytes [regexp -all -inline {[0-9A-Fa-f]+} [read $fh]]
    close $fh
    if {[llength $bytes] != $depth} {
        error "write_update_mem: $memFile has [llength $bytes] bytes, expected $depth"
    }
    set fh [open $outFile w]
    for {set a 0} {$a < $depth} {incr a 16} {
        puts $fh "@[format %08X $a] [join [lrange $bytes $a [expr {$a + 15}]] { }]"
    }
    close $fh
}

# run_updatemem <mmiFile> <bitIn> <memFiles> <bitOut>
#
# Runs updatemem for every memory instance (<Processor>) in the MMI.
# memFiles is a dict from instance name to updatemem .mem file; a key
# matches an instance whose path ends in it (ramComp matches ramComp and
# top/ramComp).  Every instance must have a file.  updatemem.bat is run
# through cmd.exe on Windows.
proc run_updatemem {mmiFile bitIn memFiles bitOut} {
    set fh [open $mmiFile r]
    set procs [regexp -all -inline -- {InstPath="([^"]+)"} [read $fh]]
    close $fh
    set args [list -force -meminfo [file nativename $mmiFile] \
                  -bit [file nativename $bitIn]]
    foreach {match inst} $procs {
        set memFile ""
        dict for {key file} $memFiles {
            if {$inst eq $key || [string match */$key $inst]} {
                set memFile $file
            }
        }
        if {$memFile eq ""} {
            error "run_updatemem: no memory file for $inst\
                   (have [join [dict keys $memFiles] {, }])"
        }
        lappend args -data [file nativename $memFile] -proc $inst
    }
    lappend args -out [file nativename $bitOut]
    set upd [file join $::env(XILINX_VIVADO) bin updatemem]
    if {$::tcl_platform(platform) eq "windows"} {
        set cmd [list cmd.exe /c call [file nativename $upd.bat] {*}$args]
    } else {
        set cmd [list $upd {*}$args]
    }
    file delete -force $bitOut
    if {[catch {exec {*}$cmd 2>@1} out]} {
        puts $out
        error "run_updatemem: updatemem failed"
    }
    puts $out
    if {![file exists $bitOut]} {
        error "run_updatemem: updatemem did not write $bitOut"
    }
}

# bit_diff_blocks <bitA> <bitB>
#
# Number of 64-byte blocks that differ between the configuration data of two
# bitstreams (from the sync word on, so the header is ignored).  -1 if the
# lengths differ.
proc bit_diff_blocks {bitA bitB} {
    set sync [binary format H8 AA995566]
    set data {}
    foreach f [list $bitA $bitB] {
        set fh [open $f rb]
        set d [read $fh]
        close $fh
        set i [string first $sync $d]
        if {$i < 0} {
            error "bit_diff_blocks: no sync word in $f"
        }
        lappend data [string range $d $i end]
    }
    lassign $data a b
    if {[string length $a] != [string length $b]} {
        return -1
    }
    set n 0
    for {set i 0} {$i < [string length $a]} {incr i 64} {
        if {[string range $a $i [expr {$i + 63}]] ne [string range $b $i [expr {$i + 63}]]} {
            incr n
        }
    }
    return $n
}
