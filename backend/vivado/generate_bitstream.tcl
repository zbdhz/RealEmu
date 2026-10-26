# 沿用已通过 validate_timing.tcl 验收的实现，仅生成 bitstream，不操作板卡。
# vivado -mode batch -source backend/vivado/generate_bitstream.tcl \
#   -tclargs RUN_DIRECTORY ?JOBS?
proc generate_realemu_bitstream {} {
    global argv
    if {[llength $argv] < 1 || [llength $argv] > 2} {
        error "Usage: generate_bitstream.tcl RUN_DIRECTORY ?JOBS?"
    }
    set run_dir [file normalize [lindex $argv 0]]
    set jobs 8
    if {[llength $argv] == 2} { set jobs [lindex $argv 1] }
    if {![string is integer -strict $jobs] || $jobs < 1} {
        error "JOBS must be a positive integer"
    }
    set project_path [file join $run_dir xdma_0_ex xdma_0_ex.xpr]
    set impl_dir [file join $run_dir xdma_0_ex xdma_0_ex.runs impl_1]
    set checkpoint [file join $impl_dir xilinx_dma_pcie_ep_postroute_physopt.dcp]
    set bitfile [file join $impl_dir xilinx_dma_pcie_ep.bit]
    set reports [file join $run_dir verification]
    set timing_result [file join $reports timing-result.txt]
    foreach required [list $project_path $checkpoint $timing_result] {
        if {![file isfile $required]} { error "Required accepted input missing: $required" }
    }

    # 验收摘要必须存在且为通过值；检查点更新后应重新跑时序验收。
    set fp [open $timing_result r]
    set timing [read $fp]
    close $fp
    set values [dict create]
    foreach line [split $timing "\n"] {
        if {[regexp {^([^=]+)=(.*)$} $line -> key value]} { dict set values $key $value }
    }
    foreach key {cycles_per_us user_clk_period_ns setup_slack_ns hold_slack_ns} {
        if {![dict exists $values $key] || ![string is double -strict [dict get $values $key]]} {
            error "Missing or invalid timing result: $key"
        }
    }
    if {[dict get $values cycles_per_us] != 250 ||
        [dict get $values user_clk_period_ns] != 4.000 ||
        [dict get $values setup_slack_ns] < 0 || [dict get $values hold_slack_ns] < 0} {
        error "Timing acceptance failed; rerun validate_timing.tcl"
    }
    if {[file mtime $checkpoint] > [file mtime $timing_result]} {
        error "Checkpoint is newer than timing acceptance; rerun validate_timing.tcl"
    }
    set checkpoint_sha [lindex [exec sha256sum -- $checkpoint] 0]
    open_project $project_path
    set impl_run [get_runs impl_1]
    foreach name {synth_1 impl_1} {
        if {[get_property NEEDS_REFRESH [get_runs $name]]} {
            error "$name needs refresh; regenerate RTL and rerun timing acceptance"
        }
    }
    set status [get_property STATUS $impl_run]
    puts "BITSTREAM_IMPL_BEFORE: $status"
    set reused [string match *write_bitstream*Complete* $status]
    if {!$reused && ![string match {*phys_opt_design*Post-Route*Complete*} $status]} {
        error "Implementation is not at an accepted post-route step: $status"
    }
    if {!$reused} {
        # 此入口不调用 reset_run；若实现失效，交由前一步重新验收。
        launch_runs impl_1 -to_step write_bitstream -jobs $jobs
        wait_on_run impl_1
    }
    set status [get_property STATUS $impl_run]
    if {![string match *write_bitstream*Complete* $status] ||
        ![file isfile $bitfile] || [file size $bitfile] == 0 ||
        [file mtime $bitfile] < [file mtime $checkpoint]} {
        error "Bitstream generation did not complete for this checkpoint: $status"
    }
    if {[lindex [exec sha256sum -- $checkpoint] 0] ne $checkpoint_sha} {
        error "Accepted checkpoint changed during bitstream generation"
    }
    set bit_sha [lindex [exec sha256sum -- $bitfile] 0]
    set fp [open [file join $reports bitstream-result.txt] w]
    puts $fp "bitstream=$bitfile"
    puts $fp "bytes=[file size $bitfile]"
    puts $fp "sha256=$bit_sha"
    puts $fp "checkpoint_sha256=$checkpoint_sha"
    puts $fp "reused_existing_bitstream=$reused"
    puts $fp "part=[get_property PART [current_project]]"
    close $fp
    close_project
    puts "REALEMU_BITSTREAM_PASS path=$bitfile bytes=[file size $bitfile] sha256=$bit_sha"
}
if {[catch {generate_realemu_bitstream} message options]} {
    puts stderr "REALEMU_BITSTREAM_FAIL: $message"
    puts stderr [dict get $options -errorinfo]
    exit 1
}
exit 0
