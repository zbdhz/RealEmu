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

    `ifdef BSIM
        UInt#(32)  clkFreq      = 1;   //the clock freq (/MHz)
    `else
        UInt#(32)  clkFreq      = 200;   //the clock freq (/MHz)
    `endif

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

    Wire#(Bool)      perValidWire       <- mkDWire(False);
    Wire#(UInt#(16)) perWire            <- mkDWire(0);
    Reg#(Bit#(16))   randomValueReg     <- mkReg(0);
    Wire#(Bool)      powerdBValidWire   <- mkDWire(False);
    Wire#(Int#(12))  powerdBWire        <- mkDWire(0);

    Reg#(Bit#(DEV_ID_WIDTH))   currentSrcipReg   <- mkReg(0);
    Reg#(Bit#(DEV_ID_WIDTH))   currentDstipReg   <- mkReg(0);
    Reg#(Bit#(DEV_ID_WIDTH))   rxSrcipReg        <- mkReg(0);
    Reg#(Bit#(DEV_ID_WIDTH))   rxDstipReg        <- mkReg(0);

    //---------------------------
    // timer 
    //---------------------------
    Wire#(Bool)         psduTimeValidWire   <- mkDWire(False);
    Wire#(UInt#(32))    psduTimeWire        <- mkDWire(0);   

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
            // $display("phyTxReqQ.enq(phyTxpkt),mypyhid:%d,srcPhyid:%d,dstPhyId:%d",id,phyTxpkt.srcPhyId,phyTxpkt.dstPhyId);
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
            MacEvent macRxpkt1 = MacEvent{
                srcMacId  : currentSrcipReg,
                dstMacId  : currentDstipReg,
                rfParam   : RfParam{power: currentPowerReg, mcs: currentMcsReg}, 
                mpduDigest: currentMpduDigest,
                status    : True
            }; 
            lowMacRxReqQ.enq(macRxpkt1);
            $display("lowMacRxReqQ.enq: %x,myphyid :%d,srcid:%d, dstid:%d ", macRxpkt1,id,macRxpkt1.srcMacId,macRxpkt1.dstMacId);
            //lowMacRxRespQ.enq(GenericResp{});
            /*  同步后的结果不传入MAC，否则会导致lowMacRxReqQ被enq两次，产生错误的结果
        end else if(syncEndReg)begin
            MacEvent macRxpkt2 = MacEvent{
                srcMacId  : currentSrcipReg,
                dstMacId  : currentDstipReg,
                rfParam   : RfParam{power: currentPowerReg, mcs: currentMcsReg}, 
                mpduDigest: currentMpduDigest,
                status    : True
            }; 
            lowMacRxReqQ.enq(macRxpkt2);
            //lowMacRxRespQ.enq(GenericResp{});*/
        end
    endrule


    //---------------------------
    //ccaBusyReg
    //---------------------------
    rule updateccaBusyReg;
    	ccaBusyReg <= (ccaTimerReg > 0) || (stateReg == PHY_TX);
    	if (psduTimeValidWire) begin
            ccaTimerReg <= (ccaTimerReg > (psduTimeWire + syncTime)) ? (ccaTimerReg - 1) : (psduTimeWire + syncTime - 1);
        end 
        else if(ccaTimerReg > 0)begin
            ccaTimerReg <= ccaTimerReg - 1;
   	    end 
        else begin
            ccaTimerReg <= 0 ;
        end
    endrule


    //---------------------------
    // psduTimeReg
    //---------------------------
    rule updata_mcs;
        if(txValidReg)
            tempMcsReg <= txMcsReg;
        else if(rxValidReg)
            tempMcsReg <= rxMcsReg;
    endrule

    UInt#(10) ndbps_lut[8] = {
        26, 
        52, 
        78, 
        104, 
        156, 
        208, 
        234, 
        260
    };

    Wire#(UInt#(10)) ndbpsWire <- mkDWire(26);

    rule updateNdbps;
        ndbpsWire <= (tempMcsReg < 8) ? ndbps_lut[tempMcsReg] : 0;
    endrule

    Server#(Tuple2#(UInt#(20),UInt#(10)), Tuple2#(UInt#(10),UInt#(10))) divider <- mkDivider(1);
    rule feed_operation;
        if(txValidReg) begin
            UInt#(20) aligned_dividend = zeroExtend(txLenReg) << 3;  
            divider.request.put(tuple2(aligned_dividend, ndbpsWire));
        end 
        else if(rxValidReg) begin
            UInt#(20) aligned_dividend = zeroExtend(rxLenReg) << 3; 
            divider.request.put(tuple2(aligned_dividend, ndbpsWire));
            //immLog("mkPhyYansWifi", "feed_operation", $format("Id %5d, Phy Rx Event", id));
            //$display("PHY_RX EVENT");
        end
    endrule

    rule divideResult;
        let result <- divider.response.get;
        let {quotient, remainder} = result;
        psduTimeWire        <= clkFreq *((cExtend(quotient) << 2) + ((remainder > 0) ? 4 : 0));
        psduTimeValidWire   <= True;
     endrule

    //---------------------------
    // stateReg
    //---------------------------
    rule handlePhyState;
        case (stateReg)
            PHY_IDLE: begin
                txEndReg <= False;
                rxEndReg <= False;
                if (txValidReg) begin
                    // 进入发送状态
                    txBeginReg      <= True;
                    stateReg        <= PHY_TX;
                    txTimerReg      <= syncTime;
                    currentMcsReg   <= txMcsReg;
                    currentPowerReg <= txPowerReg;
                    currentLenReg   <= txLenReg;
                    //$display("PHY_TX start");
                    //immLog("mkPhyYansWifi", "handlePhyState", $format("Id %5d, Phy Tx Start", id));
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
                    // if(id==0 || id == 1)
                    //     $display("%0d PHY_SYNC start, power:%d",id,rxPowerReg);
                    //$display("PHY_SYNC start, power:%d",rxPowerReg);
                    //immLog("mkPhyYansWifi", "handlePhyState", $format("Id %5d, Phy Sync Start,power: %0d", id, rxPowerReg));
                end
            end
    
            PHY_SYNC: begin
                // 同步计时器处理
                if (syncTimerReg > 0) begin
                    syncTimerReg <= syncTimerReg - 1;
                end
    
                // 数据时间设置
                if (rxBeginReg && psduTimeValidWire) begin
                    rxTimerReg <= psduTimeWire;
                    rxBeginReg <= False;
                    //$display("psdu data time: %0d (clk)", psduTimeWire);
                    //immLog("mkPhyYansWifi", "handlePhyState", $format("Id %5d, psdu data time: %0d (clk)", id, psduTimeWire));
                end
    
                // 同步结果判断
                if (perValidWire) begin
                    syncEndReg <= True;
                    if (perWire >= unpack(randomValueReg)) begin
                        stateReg    <= PHY_RX;
                        syncCrcReg  <= True;
                        // if(id==0 || id == 1)
                        //     $display("%0d PHY_SYNC OK, start PHY_RX", id);
                        //immLog("mkPhyYansWifi", "handlePhyState", $format("Id %5d, Phy Sync OK, start Phy Rx", id));
                    end 
                    else begin
                        //stateReg    <= PHY_IDLE;
                        stateReg <= PHY_RX;
                        syncCrcReg  <= False;
                        //$display("PHY_SYNC ERROR, PHY_IDLE");
                        //immLog("mkPhyYansWifi", "handlePhyState", $format("Id %5d, Phy Sync Error", id));
                    end
                end
            end
    
            PHY_RX: begin
                // 接收计时器处理
                if (rxTimerReg > 0) begin
                    rxTimerReg <= rxTimerReg - 1;
                end
    
                // CRC 校验结果
                if (perValidWire) begin
                    stateReg <= PHY_IDLE;
                    rxEndReg <= True;
                    if(perWire >= unpack(randomValueReg))begin
                        crcReg <= True;
                        // if(id==0 || id == 1)
                        //     $display("%0d CRC OK",id);
                        //immLog("mkPhyYansWifi", "handlePhyState", $format("Id %5d, CRC OK", id));
                    end else begin
                        crcReg <= False;
                        // if(id==0 || id == 1)
                        //     $display("%d CRC ERROR",id);
                        //immLog("mkPhyYansWifi", "handlePhyState", $format("Id %5d, CRC Error", id));
                    end
                end
            end
    
            PHY_TX: begin
                // 发送计时器处理
                if (txBeginReg && psduTimeValidWire) begin
                    txTimerReg <= txTimerReg + psduTimeWire - 1;
                    txBeginReg <= False;
                    // if(id==0 || id == 1)
                    //     $display("%d tx time: %0d (clk)", id, syncTime + psduTimeWire);
                    //immLog("mkPhyYansWifi", "handlePhyState", $format("Id %5d, tx time: %0d (clk)", id, syncTime + psduTimeWire));
                end 
                else if (txTimerReg > 0) begin
                    txTimerReg <= txTimerReg - 1;
                end 
                else begin
                    stateReg <= PHY_IDLE;
                    txEndReg <= True;
                    // if(id==0 || id == 1)
                    //     $display("%d PHY_TX END", id);
                    //immLog("mkPhyYansWifi", "handlePhyState", $format("Id %5d, Phy Tx End", id));
                end
            end
    
            default: begin
                stateReg <= PHY_IDLE;  // 异常恢复
                //$display("Unknown state, reset to IDLE");
                //immLog("mkPhyYansWifi", "handlePhyState", $format("Id %5d, Unknown state, reset to IDLE", id));
            end
        endcase
    endrule


    //---------------------------
    //RandI 16
    //---------------------------
    RandI#(16) randGen <- mkRn_16;


    rule getRand;
        let tmpRand    <- randGen.get();  
        randomValueReg <= tmpRand;
    endrule

    //---------------------------
    // ROM
    //---------------------------
    Rom1port#(UInt#(12),UInt#(32)) rom1 <- mkSingleRom("Lg.mem");
    Rom1port#(UInt#(14),UInt#(16)) rom2 <- mkSingleRom("Per.mem");

    rule putAddr1 if ((stateReg == PHY_SYNC || stateReg == PHY_RX) && rxValidReg);
        UInt#(12) addr1 = unpack(pack(rxPowerReg + 2047 + 1));
        rom1.request.put(addr1);
    endrule

    rule rom2Request (powerdBValidWire);
        UInt#(12) sinrAddr; UInt#(14) addr2;
        if (currentPowerReg < (lowSNR + powerdBWire)) begin
            sinrAddr = 0;
        end 
        else if (currentPowerReg >= (highSNR + powerdBWire)) begin
            sinrAddr = 1119;
        end 
        else begin
            sinrAddr = 160 + unpack(pack(currentPowerReg - powerdBWire));
        end
        
        if (stateReg == PHY_RX) begin
            addr2 = zeroExtend(unpack(pack(currentMcsReg))) * 1120 + zeroExtend(sinrAddr);
        end 
        else begin
            addr2 = zeroExtend(sinrAddr);
        end
        rom2.request.put(addr2);
        // if(id==0 || id == 1)
        //     $display("SINR : %d",addr2);

        //$display("SINR: %0d ", (currentPowerReg - powerdBWire) >> 5);
        //immLog("mkPhyYansWifi", "rom2Request", $format("Id %5d, SINR: %0d", id, (currentPowerReg - powerdBWire) >> 5));

    endrule


    //---------------------------
    // let
    //---------------------------
    Reg#(Maybe#(File)) fdReg <- mkReg(Invalid);

    // 打开文件（仅在初始化时执行一次）
    // rule openFile if (!isValid(fdReg));
    //     let fd <- $fopen("/home/psz/RealEmu/scripts/PhyCore.txt", "a");
    //     fdReg <= tagged Valid fd;
    //     $display("File opened.");
    // endrule

    rule let1;
        let tmpPer <- rom2.response.get;
        perWire <= tmpPer;
        perValidWire <= True;
        // if(stateReg == PHY_RX)begin
        //     let fd = validValue(fdReg);
        //     $fwrite(fd, "%0d\n", tmpPer);  // 写入数据并换行
        // end
        // $display("PER: %0d ", tmpPer);
        // immLog("mkPhyYansWifi", "let1", $format("Id %5d, PER: %0d", id, tmpPer));
    endrule


    //-----------------------------------
    // search
    //----------------------------------
    Reg#(UInt#(32)) currentmaxReg <- mkReg(0);
    Reg#(UInt#(32)) currentReg    <- mkDReg(0);    
    Reg#(UInt#(32)) noiseSumReg   <- mkReg(noisePower); 
    Reg#(UInt#(32)) cycleCount    <- mkReg(0);
    UInt#(32) sinrSmaple = 5 * clkFreq;   
    BinarySearchIFC searcher <- mkBinarySearch;
    rule feed_test((syncTimerReg == 30) || (rxTimerReg == 30));
        searcher.put(noiseSumReg);
        //$display("Binary searching %0d",noiseSumReg);
        //immLog("mkPhyYansWifi", "feed_test", $format("Id %5d, Binary Searching %0d", id, noiseSumReg));
    endrule

    rule search_result;
        let res <- searcher.get;
        powerdBWire<= unpack(pack(res));
        powerdBValidWire <= True;
        //$display("Binary searched %0d",res);
        //immLog("mkPhyYansWifi", "search_result", $format("Id %5d, Binary Searched %0d", id, res));
    endrule


    //---------------------------
    // SINR
    //--------------------------
    rule rom1Get;
        let data <- rom1.response.get;
        currentReg <= data;
        //$display("max : %0d",data);
        //immLog("mkPhyYansWifi", "rom1Get", $format("Id %5d, max : %0d", id, data));
    endrule

    rule updateMaxpower((stateReg == PHY_SYNC) || (stateReg == PHY_RX)) ;
        if(rxEndReg || syncEndReg) 
            currentmaxReg <= 0;
        else if(cycleCount == sinrSmaple - 1)
            currentmaxReg <= 0;
        else if (currentReg > currentmaxReg) begin
            currentmaxReg <= currentReg;
        end 
    endrule

    rule handleCycleEnd((stateReg == PHY_SYNC) || (stateReg == PHY_RX));
        if(rxEndReg || syncEndReg) begin
            noiseSumReg <=  noisePower;
        end 
        else if(cycleCount == sinrSmaple - 1) begin
            noiseSumReg <= noiseSumReg + currentmaxReg;
        end
    endrule

    rule incrementCounter((stateReg == PHY_SYNC) || (stateReg == PHY_RX));
        if(cycleCount == sinrSmaple - 1)
              cycleCount <= 0;
        else
              cycleCount <= cycleCount + 1;
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


// ================================== BinarySearchIFC ==============================
typedef 4096 ROM_SIZE;
    
interface BinarySearchIFC;
    method Action put(UInt#(32) target);
    method ActionValue#(Int#(12)) get;  // 修改返回类型
endinterface

module mkBinarySearch(BinarySearchIFC);
    // ROM接口
    Rom1port#(UInt#(12), UInt#(32)) rom3 <- mkSingleRom("Lg.mem");
    
    // 状态寄存器
    Reg#(UInt#(12))  lowReg         <- mkReg(0);
    Reg#(UInt#(12))  highReg        <- mkReg(4095);
    Reg#(UInt#(32))  targetReg      <- mkReg(0);
    Reg#(UInt#(12))  midReg         <- mkReg(0);  
    Reg#(Bool)       searchingReg   <- mkReg(False);
    Reg#(Bool)       searchWaitReg  <- mkReg(False);
    Reg#(UInt#(6))   stepReg        <- mkReg(0);
    
    FIFO#(UInt#(32)) inputQ         <- mkFIFO;
    FIFO#(UInt#(12)) outputQ        <- mkFIFO;

    // 主状态机规则
    rule startSearch (!searchingReg);
        let target = inputQ.first;
        inputQ.deq;
        targetReg    <= target;
        lowReg       <= 0;
        highReg      <= 4095;
        stepReg      <= 0;        
        searchingReg <= True;
    endrule

    rule search (searchingReg && !searchWaitReg);
        UInt#(12) mid   = (lowReg >> 1) + (highReg >> 1);
        if (stepReg < 12) begin
            rom3.request.put(mid);
            searchWaitReg  <= True;
            stepReg  <=  stepReg + 1;
            midReg   <=  mid;
        end 
        else begin
            stepReg <= 0;
            outputQ.enq(mid);
            searchingReg   <= False;
        end
    endrule

    rule handleResponse (searchingReg && searchWaitReg);
        let data <- rom3.response.get;
        searchWaitReg  <= False;
        if (data < targetReg) begin
            lowReg  <= midReg + 1;
        end 
        else if(data > targetReg)begin
            highReg  <= midReg - 1;
        end else begin
            // $display("equal");
        end 
    endrule

    method Action put(UInt#(32) target);
        inputQ.enq(target);
    endmethod

    method ActionValue#((Int#(12))) get;
        let data = outputQ.first;
        outputQ.deq;
        Int#(12) res = unpack(pack(data - 2048));
        return res;
    endmethod

endmodule



// ================================== LFSR ==============================
//export mkRn_16;
// We want 16-bit random numbers, so we will use the 16-bit version of
// LFSR and take the most significant eight bits.
// The interface for the random number generator is parameterized on bit
// length. It is a "get" interface, defined in the GetPut package.

// interface LFSR #(type a_type);
//     method Action seed(a_type seed_value);
//     method a_type value();
//     method Action next();
// endinterface: LFSR
    
typedef Get#(Bit#(n)) RandI#(type n);
module mkRn_16(RandI#(16));
    // First we instantiate the LFSR module
    LFSR#(Bit#(16)) lfsr <- mkLFSR_16 ;
    // Next comes a FIFO for storing the results until needed
    FIFO#(Bit#(16)) fi <- mkFIFO ;
    // A boolean flag for ensuring that we first seed the LFSR module
    Reg#(Bool) starting <- mkReg(True) ;
    // This rule fires first, and sends a suitable seed to the module.
    rule start (starting);
        starting <= False;
        lfsr.seed('h11);
    endrule: start
    // After that, the following rule runs as often as it can, retrieving
    // results from the LFSR module and enqueing them on the FIFO.
    rule run (!starting);
        fi.enq(lfsr.value[15:0]);
        lfsr.next;
    endrule: run
    // The interface for mkRn_6 is a Get interface. We can produce this from a
    // FIFO using the fifoToGet function. We therefore don’t need to define any
    // new methods explicitly in this module: we can simply return the produced
    // Get interface as the "result" of this module instantiation.
    return fifoToGet(fi);
endmodule
