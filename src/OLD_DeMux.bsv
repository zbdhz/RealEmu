// Copyright (C) 2025 Jingzhi Wang
// Email: jzwang@smail.nju.edu.cn
//
// This file is part of RealEmu.
//
// RealEmu is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// RealEmu is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with RealEmu.  If not, see <https://www.gnu.org/licenses/>.

import FIFO::*;
import Vector::*;
import GetPut::*;

interface DemuxPipe#(numeric type portNum, numeric type idxSz, type dataT);
    interface Put#(Tuple2#(Bit#(idxSz), dataT)) request;
    interface Vector#(portNum, Get#(dataT)) slaves;
endinterface

typedef 16 MUX_GROUP_NUM;
typedef TLog#(MUX_GROUP_NUM) MUX_GROUP_NUM_WIDTH;
typedef Bit#(MUX_GROUP_NUM_WIDTH) MuxGroupIdx;
typedef Bit#(TSub#(idxSz, MUX_GROUP_NUM_WIDTH)) MuxLocalIdx#(type idxSz);

module mkDemuxPipeline(DemuxPipe#(portNum, idxSz, dataT)) provisos (
    Bits#(dataT, dataSz), Add#(MUX_GROUP_NUM_WIDTH, _a, idxSz), 
    Add#(TLog#(portNum), _b, idxSz),  Bits#(Tuple2#(Bit#(TSub#(idxSz, 4)), dataT), _c)
    );

    Integer groupNum  = valueOf(MUX_GROUP_NUM);
    Integer groupSize = valueOf(portNum) / groupNum;

    Vector#(MUX_GROUP_NUM, FIFO#(Tuple2#(MuxLocalIdx#(idxSz), dataT))) groupQVec <- replicateM(mkFIFO);
    Vector#(MUX_GROUP_NUM, Vector#(TDiv#(portNum, MUX_GROUP_NUM), FIFO#(dataT))) slaveQVec <- replicateM(replicateM(mkFIFO));

    FIFO#(Tuple2#(Bit#(idxSz), dataT)) requestFIFO <- mkFIFO;

    // First level route：put data to the relative groupQueue
    rule processFirstStage;
        let {idx, data} = requestFIFO.first;
        requestFIFO.deq;
        MuxGroupIdx groupIdx = truncateLSB(idx);  
        MuxLocalIdx#(idxSz) localIdx = truncate(idx);
        groupQVec[groupIdx].enq(tuple2(localIdx, data));
    endrule

    // Second level route：put data from groupQueue to specific slaveQueue
    for (Integer gIdx = 0; gIdx < groupNum; gIdx = gIdx + 1) begin
        (* conflict_free = "processSecondStage" *)
        rule processSecondStage;
            let {localIdx, data} = groupQVec[gIdx].first;
            groupQVec[gIdx].deq;
            slaveQVec[gIdx][localIdx].enq(data);
        endrule
    end

    Vector#(portNum , FIFO#(dataT)) outputQVec = newVector;
    for (Integer portIdx = 0; portIdx < valueOf(portNum); portIdx = portIdx + 1) begin
        Bit#(idxSz) idx = fromInteger(portIdx);
        MuxGroupIdx groupIdx = truncateLSB(idx);  
        MuxLocalIdx#(idxSz) localIdx = truncate(idx);
        outputQVec[portIdx] = slaveQVec[groupIdx][localIdx];
    end

    interface Put request;
        method Action put(Tuple2#(Bit#(idxSz), dataT) req);
            requestFIFO.enq(req);
        endmethod
    endinterface

    interface Vector slaves = map(toGet, outputQVec);
endmodule
