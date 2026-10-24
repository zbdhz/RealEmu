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

import GetPut::*;
import FIFO::*;
import LFSR::*;
import DReg::*;

import Types::*;

typedef 20 RTS_MPDU_LEN;
typedef 14 CTS_MPDU_LEN;
typedef 14 ACK_MPDU_LEN;

// Airtimes are defined by FrameTiming, not control-frame constants.

function Bool isMyFrame(Integer id, MacId dstMacId);
    return (fromInteger(id) == dstMacId);
endfunction

function Bool isDataFrame(MpduDigest mpdu);
    return (mpdu.frameType == fromInteger(valueOf(FC_TYPE_DATA)));
endfunction

function Bool isRtsFrame(MpduDigest mpdu);
    return (mpdu.frameType == fromInteger(valueOf(FC_TYPE_CONTROL)) && 
                mpdu.frameSubType == fromInteger(valueOf(FC_CTRLSUB_RTS)));
endfunction

function Bool isCtsFrame(MpduDigest mpdu);
    return (mpdu.frameType == fromInteger(valueOf(FC_TYPE_CONTROL)) && 
                mpdu.frameSubType == fromInteger(valueOf(FC_CTRLSUB_CTS)));
endfunction

function Bool isAckFrame(MpduDigest mpdu);
    return (mpdu.frameType == fromInteger(valueOf(FC_TYPE_CONTROL)) && 
                mpdu.frameSubType == fromInteger(valueOf(FC_CTRLSUB_ACK)));
endfunction

function MacEvent setRtsFrame(MacEvent refFrame);
    let rtsFrame = refFrame;
    rtsFrame.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_CONTROL));
    rtsFrame.mpduDigest.frameSubType = fromInteger(valueOf(FC_CTRLSUB_RTS));
    rtsFrame.mpduDigest.length = fromInteger(valueOf(RTS_MPDU_LEN));
    rtsFrame.rfParam.mcs = 0;  // RTS use the lowest speed
    // rtsFrame.rfParam.power = 32*30;
    rtsFrame.rfParam.power = refFrame.rfParam.power;
    return rtsFrame;
endfunction

function MacEvent setCtsFrame(Integer id, MacEvent refFrame);
    let ctsFrame = refFrame;
    ctsFrame.dstMacId = refFrame.srcMacId;
    ctsFrame.srcMacId = fromInteger(id);
    ctsFrame.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_CONTROL));
    ctsFrame.mpduDigest.frameSubType = fromInteger(valueOf(FC_CTRLSUB_CTS));
    ctsFrame.mpduDigest.length = fromInteger(valueOf(CTS_MPDU_LEN));
    ctsFrame.rfParam.mcs = 0;  // CTS use the lowest speed
    // ctsFrame.rfParam.power = 32*30;
    ctsFrame.rfParam.power = refFrame.rfParam.power;
    return ctsFrame;
endfunction

function MacEvent setAckFrame(Integer id, MacEvent refFrame);
    let ackFrame = refFrame;
    ackFrame.dstMacId = refFrame.srcMacId;
    ackFrame.srcMacId = fromInteger(id);
    ackFrame.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_CONTROL));
    ackFrame.mpduDigest.frameSubType = fromInteger(valueOf(FC_CTRLSUB_ACK));
    ackFrame.mpduDigest.length = fromInteger(valueOf(ACK_MPDU_LEN));
    ackFrame.rfParam.mcs = 0;  // ACK use the lowest speed
    // ackFrame.rfParam.power = 32*30;
    ackFrame.rfParam.power = refFrame.rfParam.power;
    return ackFrame;
endfunction


// 指数增长随机退避窗口生成器
interface ExpBackOffGenerator;
    method ContWindowExp currentCW();
    method Action    incrCW();              // 碰撞后指数增长窗口
    method Action    resetCW();             // 成功接收窗口重置
    interface Get#(TimeSlot)  next;         // 获取下一个随机退避窗口大小
    interface Put#(MacConfig) putmaccfg;    // 配置退避状态机参数
endinterface

module mkExpBackoffGenerator#(Integer id)(ExpBackOffGenerator);
    Reg#(MacConfig) cfgReg <- mkReg(getDefaultMacCfg);
    Reg#(ContWindowExp) cwExpReg <- mkReg(getDefaultMacCfg.cwMin);
    // Per-node nonzero sequence, advanced ONLY when a new sample is consumed.
    Reg#(Bit#(16)) randomState <- mkReg(16'h1 ^ fromInteger(id * 4051));
    method Action incrCW();
        cwExpReg <= cwExpReg >= cfgReg.cwMax ? cfgReg.cwMax : cwExpReg + 1;
    endmethod
    method Action resetCW();
        cwExpReg <= cfgReg.cwMin;
    endmethod
    interface Get next;
        method ActionValue#(TimeSlot) get;
            Bit#(16) mask = (1 << cwExpReg) - 1;
            Bit#(16) nextState = (randomState >> 1) ^ (randomState[0] == 1 ? 16'hB400 : 0);
            randomState <= nextState;
            return randomState & mask;
        endmethod
    endinterface
    method ContWindowExp currentCW() = cwExpReg;
    interface Put putmaccfg;
        method Action put(MacConfig cfg);
            cfgReg <= cfg;
            if (cfg.cwMin != cfgReg.cwMin || cfg.cwMax != cfgReg.cwMax)
                cwExpReg <= cfg.cwMin;
            if (cfg.backoffSeed != cfgReg.backoffSeed) begin
                Bit#(16) seed = cfg.backoffSeed ^ fromInteger(id * 4051);
                randomState <= seed == 0 ? 1 : seed;
            end
        endmethod
    endinterface
endmodule

// Us and Slot Generator
interface TimeGen;
    method Bool get();
endinterface

typedef UInt#(16) CycleCnt;

module mkUsGen#(Integer usCycle)(TimeGen);
    Reg#(Bool)       usTrigger  <- mkDReg(False);
    Reg#(CycleCnt)   counterReg <- mkReg(0);

    rule count;
        if (counterReg == fromInteger(usCycle-1)) begin
            counterReg <= 0;
            usTrigger <= True;
        end
        else begin
            counterReg <= counterReg + 1;
        end
    endrule

    method Bool get();
        return usTrigger;
    endmethod
endmodule

module mkSlotGen#(TimeGen usGen, Reg#(MacConfig) cfg)(TimeGen);
    Reg#(Bool)    slotTrigger <- mkDReg(False);
    Reg#(TimeUs)  usReg       <- mkReg(0);
    Reg#(TimeUs)  slotReg     <- mkReg(getDefaultMacCfg.slot);

    rule count;
        // Rebase when slot changes, including a reduction below usReg.
        if (slotReg != cfg.slot) begin
            slotReg <= cfg.slot;
            usReg <= 0;
        end
        else if (usGen.get && cfg.slot != 0) begin
            if (usReg >= cfg.slot - 1) begin
                usReg <= 0;
                slotTrigger <= True;
            end
            else begin
                usReg <= usReg + 1;
            end
        end
    endrule

    method Bool get();
        return slotTrigger;
    endmethod
endmodule

