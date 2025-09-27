include ../Makefile.base

TCLDIR ?= xdc
CLK ?= emu_clock
OOC ?= 1
VLOGDIR ?= ./verilog
OUTPUTDIR ?= output
LOGFILE ?= run.log
RUNTOPHASE ?= all # synth place route all
PARTNAME = xcvu13p-fhgb2104-2-i

TARGETFILE ?= ../src/BsvTov_simple.bsv
TOPMODULE ?= mkRawEmuCore

# TARGETFILE ?= ../src/BsvTop_fake.bsv
# TOPMODULE ?= mkRawEmuCore

# TARGETFILE ?= ../src/PhyCore.bsv
# TOPMODULE ?= mkPhyYansWifi

# TARGETFILE ?= ../src/Channel.bsv
# TOPMODULE ?= mkGainLossModelLogDistance

# TARGETFILE ?= ../src/Arbitration.bsv
# TOPMODULE ?= mkArbiter

# TARGETFILE ?= ../src/MacBridge.bsv
# TOPMODULE ?= mkMacBridge

# TARGETFILE ?= ../src/CfgBridge.bsv
# TOPMODULE ?= mkCfgBridge

BACKENDDIR ?= .
MAX_NET_PATH_NUM ?= 10000
VERILOG_TOPMODULE ?= top

# IMPORT_VERILOG_DIR := +:../src/third_party/blue-crc/lib/primitives
# IMPORT_VERILOG_DIR := $(shell echo "$(IMPORT_VERILOG_DIR)" | tr -d ' ')


export TOP = $(TOPMODULE)
export DIR_RTL = $(VLOGDIR)
export DIR_XDC = $(TCLDIR)
export DIR_OOC_SCRIPTS = $(BACKENDDIR)/ooc_tcl_and_xdc
export DIR_IPS = $(BACKENDDIR)/ips
export DIR_IP_GENERATED = $(BUILDDIR)/ips
export DIR_BSV_GENERATED = $(BACKENDDIR)/verilog
export VERILOG_TOPMODULE
export TARGET_CLOCKS = $(CLK)
export DIR_OUTPUT = $(OUTPUTDIR)
export OOCSYNTH = $(OOC)
export RUNTO = $(RUNTOPHASE)
export PART = $(PARTNAME)
export MAX_NET_PATH_NUM

export DIR_BSV_GENERATED_STUB = $(BACKENDDIR)/verilog/stub

compile:
	mkdir -p $(BUILDDIR)
	bsc -elab -sim -verbose $(BLUESIMFLAGS) $(DEBUGFLAGS) $(DIRFLAGS) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(SCHEDFLAGS) $(TRANSFLAGS) -g $(TOPMODULE) $(TARGETFILE)

verilog: compile 
	mkdir -p $(VLOGDIR)
	bsc $(VERILOGFLAGS) $(DIRFLAGS) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(TRANSFLAGS) -g $(TOPMODULE) $(TARGETFILE)
	bluetcl listVlogFiles.tcl -bdir $(BUILDDIR) -vdir $(BUILDDIR) $(TOPMODULE) $(TOPMODULE) | grep -i '\.v' | xargs -I {} cp {} $(VLOGDIR)

vivado: verilog
	vivado -mode tcl -nolog -nojournal -source ./build_top.tcl 2>&1 | tee $(LOGFILE)

vivado_synth:
	vivado -mode tcl -nolog -nojournal -source ./build_top.tcl -tclargs synth 2>&1 | tee $(LOGFILE)

vivado_batch: vivado_synth
	vivado -mode tcl -nolog -nojournal -source ./build_top.tcl -tclargs prw ExtraNetDelay_high 2>&1 | tee ext.out & \
	vivado -mode tcl -nolog -nojournal -source ./build_top.tcl -tclargs prw WLDrivenBlockPlacement 2>&1 | tee wld.out & \
	wait;

clean:
	rm -rf $(BUILDDIR) $(OUTPUTDIR) $(DIR_BSV_GENERATED) $(DIR_BSV_GENERATED_STUB) .Xil *.jou *.log

.PHONY: verilog vivado clean
.DEFAULT_GOAL := verilog
