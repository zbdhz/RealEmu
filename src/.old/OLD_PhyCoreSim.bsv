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

//psz


import GetPut::*;
import FIFO::*;
import FIFOF::*;
import ClientServer::*;
import DReg::*;
import BUtils ::*;
import RegFile::*;

import LFSR::*;
import Divide::*;

import ROM::*;
import Types::*;
import PrimUtils::*;


interface PhyCore;
    interface MacSrv lowMacTxSrv;
    interface MacClt lowMacRxClt;

    interface PhySrv phyRxSrv;
    interface PhyClt phyTxClt;

    //interface PhyCfgSrv configSrv;

    method PhyStatus getPhyStatus;
endinterface


///============================= phyState =====================================
/// Int#(12) powerdB Q6.5       UInt#(32) powerLinear U24.8
///============================================================================
//(* synthesize *)
module mkPhyYansWifi#(Integer id)(PhyCore);
    FIFOF#(MacEvent)    lowMacTxReqQ      <- mkFIFOF;
    FIFOF#(GenericResp) lowMacTxRespQ     <- mkFIFOF;
    FIFOF#(MacEvent)    lowMacRxReqQ      <- mkFIFOF;
    FIFOF#(GenericResp) lowMacRxRespQ     <- mkFIFOF;

    FIFOF#(PhyEvent)    phyTxReqQ         <- mkFIFOF;
    FIFOF#(GenericResp) phyTxRespQ        <- mkFIFOF;
    FIFOF#(PhyEvent)    phyRxReqQ         <- mkFIFOF;
    FIFOF#(GenericResp) phyRxRespQ        <- mkFIFOF;


    UInt#(32)  clkFreq      = 1;   //the clock freq (/MHz)

    UInt#(32)  syncTime     = 48 * clkFreq;  
    UInt#(32)  noisePower   = 256; //1mW   
    Int#(12)   lowSNR       = -160;   
    Int#(12)   highSNR      = 960;
    Int#(12)   threash      =-960;   // threash = -30dBm  
    //---------------------------
    //reg wire 
    //---------------------------
    Reg#(Bool)       txBeginReg         <- mkReg(False);
    Reg#(Bool)       txEndReg           <- mkReg(False);
    Reg#(Bool)       rxBeginReg         <- mkReg(False);
    Reg#(Bool)       rxEndReg           <- mkReg(False);

    Reg#(Int#(12))   currentPowerReg    <- mkReg(0);     
    Reg#(Mcs)        currentMcsReg      <- mkReg(0);
    Reg#(UInt#(16))  currentLenReg      <- mkReg(0);
    Reg#(MpduDigest) currentMpduDigest  <- mkReg(getEmptyMpduDigest);

    Reg#(Bool)       rxValidReg         <- mkDReg(False); 
    Reg#(Int#(12))   rxPowerReg         <- mkReg(0);   
    Reg#(Mcs)        rxMcsReg           <- mkReg(0);
    Reg#(UInt#(16))  rxLenReg           <- mkReg(0);
    Reg#(MpduDigest) rxMpduDigest       <- mkReg(getEmptyMpduDigest); 
    
    Reg#(Bool)       txValidReg         <- mkDReg(False); 
    Reg#(Mcs)        txMcsReg           <- mkReg(0);
    Reg#(Int#(12))   txPowerReg         <- mkReg(0);   
    Reg#(UInt#(16))  txLenReg           <- mkReg(0);    
    Wire#(Mcs)       tempMcsReg         <- mkDWire(0);
    
    Reg#(PhyFsmState)stateReg           <- mkReg(PHY_IDLE); 
    Wire#(Bool)      ccaBusyReg         <- mkDWire(False); 
    Reg#(Bool)       syncCrcReg         <- mkDReg(False);
    Reg#(Bool)       syncEndReg         <- mkDReg(False);
    Reg#(Bool)       crcReg             <- mkDReg(False);

    Reg#(Bit#(DEV_ID_WIDTH))   currentSrcipReg   <- mkReg(0);
    Reg#(Bit#(DEV_ID_WIDTH))   currentDstipReg   <- mkReg(0);
    Reg#(Bit#(DEV_ID_WIDTH))   rxSrcipReg        <- mkReg(0);
    Reg#(Bit#(DEV_ID_WIDTH))   rxDstipReg        <- mkReg(0);


    Reg#(UInt#(32))     rxTimerReg          <- mkReg(0);     
    Reg#(UInt#(32))     syncTimerReg        <- mkReg(0);     
    Reg#(UInt#(32))     txTimerReg          <- mkReg(clkFreq * 48);   
    Reg#(UInt#(32))     ccaTimerReg         <- mkReg(0);  

    //---------------------
    //FIFOF
    //---------------------
    rule handshakeTx;
        phyTxRespQ.deq;
    endrule

    rule handshakeRx;
       lowMacRxRespQ.deq;
    endrule

    rule handleLowMacTxReqQ;
        if (lowMacTxReqQ.notEmpty) begin
            let lowMactxReq = lowMacTxReqQ.first;
            lowMacTxReqQ.deq;
            lowMacTxRespQ.enq(GenericResp{});

        //将mac包信息提取变成phy包 
            PhyEvent phyTxpkt = PhyEvent{
                srcPhyId  : lowMactxReq.srcMacId,
                dstPhyId  : lowMactxReq.dstMacId,
                rfParam   : lowMactxReq.rfParam, 
                ppduLen   : unpack(pack(lowMactxReq.mpduDigest.length)), 
                mpduDigest: lowMactxReq.mpduDigest
            }; 
            phyTxReqQ.enq(phyTxpkt);
            //phyTxRespQ.enq(GenericResp{});

            txValidReg  <= True;
            txMcsReg    <= phyTxpkt.rfParam.mcs;
            txPowerReg  <= phyTxpkt.rfParam.power;
            txLenReg    <= unpack(pack(phyTxpkt.ppduLen));
        end 
    endrule


    rule handlePhyRxReqQ;
        if (phyRxReqQ.notEmpty) begin
            let phyRxpkt = phyRxReqQ.first;
            phyRxReqQ.deq;
            phyRxRespQ.enq(GenericResp{});
            
            rxValidReg  <= True;
            rxSrcipReg  <= phyRxpkt.srcPhyId;
            rxDstipReg  <= phyRxpkt.dstPhyId;
            rxMcsReg    <= phyRxpkt.rfParam.mcs;
            rxPowerReg  <= phyRxpkt.rfParam.power;
            rxLenReg    <= unpack(pack(phyRxpkt.ppduLen));
            rxMpduDigest<= phyRxpkt.mpduDigest;
        end
    endrule

    rule handleLowMacRxReqQ;
        //crc校验通过才会传
        if (crcReg)begin
            let dstId = currentDstipReg;
            MacEvent macRxpkt1 = MacEvent{
                srcMacId  : currentSrcipReg,
                dstMacId  : dstId,
                rfParam   : RfParam{power: currentPowerReg, mcs: currentMcsReg}, 
                mpduDigest: currentMpduDigest,
                status    : crcReg
            }; 
        if(dstId == fromInteger(id))
            lowMacRxReqQ.enq(macRxpkt1);
        end
    endrule


    //---------------------------
    //ccaBusyReg
    //---------------------------
    rule updateccaBusyReg;
    	ccaBusyReg <= (ccaTimerReg > 0) || (stateReg == PHY_TX);
    	if (txValidReg || rxValidReg) begin
            ccaTimerReg <= (ccaTimerReg > (452 + syncTime)) ? (ccaTimerReg - 1) : (452 + syncTime - 1);
        end 
        else if(ccaTimerReg > 0)begin
            ccaTimerReg <= ccaTimerReg - 1;
   	    end 
        else begin
            ccaTimerReg <= 0 ;
        end
    endrule


    Reg#(Bool)  nocrc  <- mkReg(False);

    //---------------------------
    // stateReg
    //---------------------------
    rule handlePhyState;
        case (stateReg)
            PHY_IDLE: begin
                txEndReg <= False;
                rxEndReg <= False;
                nocrc <= False;
                if (txValidReg) begin
                    // 进入发送状态
                    txBeginReg      <= True;
                    stateReg        <= PHY_TX;
                    txTimerReg      <= syncTime;
                    currentMcsReg   <= txMcsReg;
                    currentPowerReg <= txPowerReg;
                    currentLenReg   <= txLenReg;
                end
                else if (rxValidReg && (rxPowerReg > threash)) begin
                    // 进入同步状态
                    rxBeginReg      <= True;
                    stateReg        <= PHY_SYNC;
                    syncTimerReg    <= syncTime;
                    currentSrcipReg <= rxSrcipReg;
                    currentDstipReg <= rxDstipReg;
                    currentMcsReg   <= rxMcsReg;
                    currentPowerReg <= rxPowerReg;
                    currentLenReg   <= rxLenReg;
                    currentMpduDigest <= rxMpduDigest;
                end
            end
    
            PHY_SYNC: begin
                // 同步计时器处理
                if (syncTimerReg > 0) begin
                    syncTimerReg <= syncTimerReg - 1;
                end                 // 同步结果判断
                else begin
                    syncEndReg <= True;
                    stateReg    <= PHY_RX;
                end
    
                if (rxBeginReg) begin
                    rxTimerReg <= 452;
                    rxBeginReg <= False;
                end

                if(rxValidReg)begin
                    nocrc <= True;
                end

            end
    
            PHY_RX: begin
                // 接收计时器处理
                if (rxTimerReg > 0) begin
                    rxTimerReg <= rxTimerReg - 1;
                end
                // CRC 校验结果
                else begin
                    stateReg <= PHY_IDLE;
                    rxEndReg <= True;
                    if(nocrc)begin
                        crcReg <= False;
                    end else begin
                        crcReg <= True;
                    end
                end
                
                if(rxValidReg)begin
                    nocrc <= True;
                end
            end
    
            PHY_TX: begin
                // 发送计时器处理
                if (txBeginReg) begin
                    txTimerReg <= txTimerReg + 452 - 1;
                    txBeginReg <= False;
                end 
                else if (txTimerReg > 0) begin
                    txTimerReg <= txTimerReg - 1;
                end 
                else begin
                    stateReg <= PHY_IDLE;
                    txEndReg <= True;
                end
            end
    
            default: begin
                stateReg <= PHY_IDLE; 
            end
        endcase
    endrule

    //---------------------------
    // interface method
    //---------------------------
    interface lowMacTxSrv = toGPServer(lowMacTxReqQ, lowMacTxRespQ);
    interface lowMacRxClt = toGPClient(lowMacRxReqQ, lowMacRxRespQ);

    interface phyTxClt    = toGPClient(phyTxReqQ, phyTxRespQ);
    interface phyRxSrv    = toGPServer(phyRxReqQ, phyRxRespQ);
    
    method PhyStatus getPhyStatus;
        return PhyStatus {
            cca         : ccaBusyReg,
            fcsEn       : rxEndReg,
            fcsCorrect  : crcReg
            };
    endmethod
endmodule

