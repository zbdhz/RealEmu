import FIFO::*;
import Randomizable::*;
import Vector::*;
import GetPut::*;

import PrimUtils::*;
import DeMux::*;

typedef 1024 TEST_DEMUX_PORT;
typedef TLog#(TEST_DEMUX_PORT) DEMUX_IDX_WIDTH;
typedef Bit#(DEMUX_IDX_WIDTH) DemuxIdx;
typedef Bit#(16) DemuxData; 

typedef 100 TestNum;

module mkTestDemuxPipe(Empty);
    DemuxPipe#(TEST_DEMUX_PORT, DEMUX_IDX_WIDTH, DemuxData) dut <- mkDemuxPipeline;

    FIFO#(Tuple2#(DemuxIdx, DemuxData)) pipeQ <- mkFIFO;
    Reg#(DemuxData) inputDataReg  <- mkReg(0);
    Reg#(DemuxData) outputDataReg <- mkReg(0);
    Reg#(UInt#(32)) cntReg        <- mkReg(0);
    Reg#(Bool)      isInitReg     <- mkReg(False);

    Randomize#(DemuxIdx) idxGen  <- mkGenericRandomizer;  

    rule testInit if (!isInitReg);
        isInitReg <= True;
        idxGen.cntrl.init;
    endrule

    rule testInput if (isInitReg);
        let idx <- idxGen.next;
        let data = zeroExtend(idx);   // construct request
        dut.request.put(tuple2(idx, data));
        inputDataReg <= inputDataReg + 1;
        cntReg <= cntReg + 1;
    endrule

    for (Integer portIdx = 0; portIdx < valueOf(TEST_DEMUX_PORT); portIdx = portIdx + 1) begin
        rule testOutput if (isInitReg);
            let data <- dut.slaves[portIdx].get;
            immAssert(
                (data == fromInteger(portIdx) ),
                "testOutput @ mkTestDemux",
                $format("Error output, get data: %d, expect data: %d", data, portIdx)
            );
        endrule
    end

    rule testEnd if (isInitReg && cntReg == fromInteger(valueOf(TestNum)));
        $display("Test Pass!");
        $finish();
    endrule

endmodule