include ../Makefile.base

# TESTFILE ?= TestChannel.bsv
# TOPMODULE ?= mkTestLogDistanceGainLossModel

# TESTFILE ?= TestTop_new.bsv 
# TOPMODULE ?= mkTestTop

# TESTFILE ?= TestBsvTop.bsv 
# TOPMODULE ?= mkTestRawEmuCore

# TESTFILE ?= TestBsvTop.bsv 
# TOPMODULE ?= mkTestRawEmuCore

TESTFILE ?= TestBsvTop_collision.bsv 
TOPMODULE ?= mkTestRawEmuCore_collision

# TESTFILE ?= TestPhySinrStats.bsv
# TOPMODULE ?= mkTestPhySinrStats

# TESTFILE ?= TestMacBridge.bsv
# TOPMODULE ?= mkTestMacBridge

# TESTFILE ?= TestPhy.bsv
# TOPMODULE ?= mkTestPhy

SCRIPT_DIR = ../scripts
MEM_DIR = ../mem

DIR_BSV_GENERATED ?= $(BUILDDIR)

SIMSCRIPT_NAME = ./$(TOPMODULE).sh

MISCFLAGS += -D IS_DEBUG=True

compile:
	mkdir -p $(BUILDDIR)
	bsc +RTS -K64M -RTS -elab -sim -verbose $(BLUESIMFLAGS) $(DEBUGFLAGS) $(DIRFLAGS) $(MISCFLAGS) $(RECOMPILEFLAGS) $(RUNTIMEFLAGS) $(SCHEDFLAGS) $(TRANSFLAGS) -g $(TOPMODULE) $(TESTFILE)
	python3 $(SCRIPT_DIR)/genRam.py && mv bram_*.txt $(BUILDDIR) 
	cp $(MEM_DIR)/*.mem $(BUILDDIR)

link: compile
	bsc +RTS -K64M -RTS -sim $(BLUESIMFLAGS) $(DIRFLAGS) $(RECOMPILEFLAGS) $(SCHEDFLAGS) $(TRANSFLAGS) -e $(TOPMODULE) -o $(BUILDDIR)/$(SIMSCRIPT_NAME) $(BSV_C_EXT_FILES)

simulate: link
	cd $(BUILDDIR) && $(SIMSCRIPT_NAME)

clean:
	rm -rf $(BUILDDIR) *.txt

.PHONY: compile simulate clean
.DEFAULT_GOAL := simulate