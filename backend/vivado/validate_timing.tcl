# 在独立的 XDMA 模板副本中重跑实现并验收时序，不操作板卡。
# vivado -mode batch -source backend/vivado/validate_timing.tcl \
#   -tclargs RUN_DIRECTORY REPO_ROOT ?REFERENCE_DCP?
proc validate_realemu {} {
    global argv
    if {[llength $argv] < 2 || [llength $argv] > 3} {
        error "Usage: validate_timing.tcl RUN_DIRECTORY REPO_ROOT ?REFERENCE_DCP?"
    }
    set run_dir [file normalize [lindex $argv 0]]
    set repo [file normalize [lindex $argv 1]]
    set project_dir [file join $run_dir xdma_0_ex]
    set rtl_dir [file join $project_dir xdma_0_ex.srcs sources_1 new]
    set reports [file join $run_dir verification]
    # 先确认输入，避免把错误路径当成新工程目录。
    foreach required [list [file join $project_dir xdma_0_ex.xpr] \
                           [file join $repo src Types.bsv] \
                           [file join $rtl_dir bram_one.txt]] {
        if {![file isfile $required]} { error "Required input missing: $required" }
    }
    if {[llength [glob -nocomplain -directory $rtl_dir *.v]] == 0 ||
        [llength [glob -nocomplain -directory $rtl_dir *.mem]] == 0} {
        error "Verilog or memory initialization files missing from $rtl_dir"
    }
    if {[llength $argv] == 3 && [lindex $argv 2] ne "" &&
        ![file isfile [file normalize [lindex $argv 2]]]} {
        error "Reference checkpoint missing: [lindex $argv 2]"
    }
    file mkdir $reports
    set fp [open [file join $repo src Types.bsv] r]
    set types_source [read $fp]
    close $fp
    if {![regexp {`define REALEMU_US_CYCLES ([0-9]+)} $types_source -> cycles]} {
        error "Cannot determine model cycles/us"
    }
    open_project [file join $project_dir xdma_0_ex.xpr]
    set frequency [get_property CONFIG.axisten_freq [get_ips xdma_0]]
    if {$frequency != $cycles} { error "Model $cycles cycles/us differs from XDMA $frequency MHz" }
    # Remove the copied template's generated RTL registration, then add only
    # this build's package. Keep the original board/IP constraints unchanged.
    foreach source [get_files -all] {
        if {[string match */sources_1/new/* [get_property NAME $source]]} { remove_files $source }
    }
    set rtl [glob -directory $rtl_dir *.v]
    set memories [concat [glob -directory $rtl_dir *.mem] [list [file join $rtl_dir bram_one.txt]]]
    add_files -norecurse [concat $rtl $memories]
    set_property FILE_TYPE {Memory Initialization Files} [get_files $memories]
    set_property TOP xilinx_dma_pcie_ep [get_filesets sources_1]
    set_property INCLUDE_DIRS [list $rtl_dir [file join $project_dir imports]] [get_filesets sources_1]
    foreach run {synth_1 impl_1} {
        set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs $run]
        set_property INCREMENTAL_CHECKPOINT {} [get_runs $run]
    }
    # 可选复用先前真实实现的物理位置；仍对本次 RTL 重新综合、布线和检查时序。
    # 不增加时序例外，也不把参考检查点的时序结果当作本次验收。
    if {[llength $argv] > 2 && [lindex $argv 2] ne ""} {
        set reference [file normalize [lindex $argv 2]]
        if {![file exists $reference]} { error "Reference checkpoint missing: $reference" }
        set_property INCREMENTAL_CHECKPOINT $reference [get_runs impl_1]
    }
    set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
    set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
    reset_run synth_1
    update_compile_order -fileset sources_1
    report_compile_order -used_in synthesis -file [file join $reports compile_order.rpt]
    launch_runs impl_1 -to_step {phys_opt_design (Post-Route)} -jobs 8
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
        error "Implementation did not complete: [get_property STATUS [get_runs impl_1]]"
    }
    open_run impl_1
    report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose \
        -file [file join $reports timing_summary.rpt]
    report_utilization -file [file join $reports utilization.rpt]
    report_route_status -file [file join $reports route_status.rpt]
    report_drc -file [file join $reports drc.rpt]
    set setup [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
    set hold [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
    set period [get_property PERIOD [get_clocks user_clk]]
    set fp [open [file join $reports timing-result.txt] w]
    puts $fp "cycles_per_us=$cycles"
    puts $fp "user_clk_period_ns=$period"
    puts $fp "setup_slack_ns=$setup"
    puts $fp "hold_slack_ns=$hold"
    puts $fp "part=[get_property PART [current_project]]"
    close $fp
    if {$period != 4.000 || $setup < 0 || $hold < 0} { error "Timing not met: setup=$setup hold=$hold period=$period" }
    close_project
    puts "REALEMU_TIMING_PASS setup=$setup hold=$hold period=$period"
}
if {[catch {validate_realemu} message options]} {
    puts stderr "REALEMU_TIMING_FAIL: $message"
    puts stderr [dict get $options -errorinfo]
    exit 1
}
exit 0
