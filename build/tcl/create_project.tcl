# create_project.tcl
#
# Vivado script: creates the Vivado project project/placard.xpr from the
# sources in src/ (every .vhd file in src/hdl is a design source).  The project folder is not kept in git (Vivado rewrites
# the .xpr every time it opens it), so this script is the record of the
# project settings.  Change a setting here, not only in the GUI, or it is
# lost the next time the project is made.
#
#     vivado -mode batch -source create_project.tcl [-tclargs force]
#
#     force     delete an existing project/ folder and make it again
#
# Called by create_project.bat, and by build_and_load.tcl when
# project/placard.xpr does not exist.  If src/hdl/ram.mem or src/hdl/rom.mem
# does not exist it is made first (gen_video_ram.tcl, and gen_rom.tcl with
# the default program).
#
# Date: 10/16/2026

set tclDir  [file dirname [file normalize [info script]]]
set repoDir [file normalize [file join $tclDir .. ..]]
set projDir [file join $repoDir project]
set srcDir  [file join $repoDir src]
set xprFile [file join $projDir placard.xpr]

set force 0
if {[info exists argv] && [lsearch -nocase $argv force] >= 0} {
    set force 1
}
if {[file exists $xprFile] && !$force} {
    error "create_project: $xprFile already exists (pass force to make it again)"
}

# ---- memory images (synthesis sources, not kept in git) ---------------------
# ram.mem initializes the RAM (ramComp), rom.mem the ROM (romComp)
set ramFile [file join $srcDir hdl ram.mem]
set romFile [file join $srcDir hdl rom.mem]
if {![file exists $ramFile]} {
    source [file join $srcDir scripts gen_video_ram.tcl]
}
if {![file exists $romFile]} {
    source [file join $srcDir scripts gen_rom.tcl]
}

# ---- project ----------------------------------------------------------------
create_project placard $projDir -part xc7a35tcpg236-1 -force
set_property target_language VHDL         [current_project]
set_property default_lib     xil_defaultlib [current_project]

# ---- design sources ---------------------------------------------------------
# every .vhd file in src/hdl
set srcs [lsort [glob -nocomplain -directory [file join $srcDir hdl] *.vhd]]
if {[llength $srcs] == 0} {
    error "create_project: no .vhd files in [file join $srcDir hdl]"
}
add_files -fileset sources_1 $srcs
set_property file_type {VHDL 2008} [get_files $srcs]
add_files -fileset sources_1 [list $ramFile $romFile]

add_files -fileset sources_1 [file join $srcDir ip clk_wiz_0.xci]
if {[llength [get_ips -filter {UPGRADE_VERSIONS != ""}]] > 0} {
    upgrade_ip [get_ips -filter {UPGRADE_VERSIONS != ""}]
}

set_property top basys_top [get_filesets sources_1]

# ---- constraints ------------------------------------------------------------
add_files -fileset constrs_1 [file join $srcDir constraints basys3_master.xdc]

# ---- simulation -------------------------------------------------------------
set tbFiles {
    tb_basys_demo.vhd
    tb_video.vhd
    tb_alu.vhd
    tb_counters.vhd
    tb_cart_load.vhd
}
set tbs {}
foreach f $tbFiles {
    lappend tbs [file join $srcDir sim $f]
}
add_files -fileset sim_1 $tbs
set_property file_type {VHDL 2008} [get_files -of_objects [get_filesets sim_1] $tbs]

set wcfgFiles {
    tb_alu_behav.wcfg
    tb_counters_behav.wcfg
    tb_video_behav.wcfg
    tb_basys_demo_behav.wcfg
}
foreach f $wcfgFiles {
    add_files -fileset sim_1 [file join $srcDir sim $f]
}
# only the waveform for the active testbench is loaded
foreach f {tb_alu_behav.wcfg tb_counters_behav.wcfg tb_video_behav.wcfg} {
    set_property is_enabled false [get_files -of_objects [get_filesets sim_1] $f]
}

set simSet [get_filesets sim_1]
set_property top                   tb_basys_demo  $simSet
set_property top_lib               xil_defaultlib $simSet
set_property xsim.simulate.runtime 40ms           $simSet

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# ---- runs -------------------------------------------------------------------
set synthRun [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.KEEP_EQUIVALENT_REGISTERS true $synthRun
set_property STEPS.SYNTH_DESIGN.ARGS.BUFG                      0    $synthRun

set implRun [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true $implRun
set_property STEPS.WRITE_BITSTREAM.ARGS.BIN_FILE         true $implRun

close_project
puts "create_project: made $xprFile"
