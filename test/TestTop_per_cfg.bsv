import GetPut::*;
import Connectable::*;
import ClientServer::*;
import BRAM::*;
import ROM::*;
import Vector::*;
import FIFOF::*;
import StmtFSM::*;
import FIFO::*;
import SemiFifo::*;

import BusConversion::*;
import AxiStreamTypes::*;
import Types::*;
import MacCore::*;
import PhyCore::*;
import CsmaUtils::*;
import PrimUtils::*;
import Channel::*;
import Arbitration::*;
import MacBridge::*;
import CfgBridge::*;
// import BsvTop::*;
import BsvTov_simple::*;
import Axi4LiteTypes::*;
import CfgAxiLite::*;


typedef 16 TEST_NODE_NUM;
function String digitToChar(Integer d);
    case (d)
        0: return "0";
        1: return "1";
        2: return "2";
        3: return "3";
        4: return "4";
        5: return "5";
        6: return "6";
        7: return "7";
        8: return "8";
        9: return "9";
        default: return "?";
    endcase
endfunction

function String intToString(Integer val);
    if (val < 10) begin
        return digitToChar(val);
    end else if (val < 100) begin
        Integer tens = val / 10;
        Integer ones = val % 10;
        return digitToChar(tens) + digitToChar(ones);
    end else if (val < 1000) begin
        Integer hundreds = val / 100;
        Integer rem = val % 100;
        Integer tens = rem / 10;
        Integer ones = rem % 10;
        return digitToChar(hundreds) + digitToChar(tens) + digitToChar(ones);
    end else if (val == 1000) begin
        return "1000";
    end else if (val == 1023) begin
        return "1023";
    end else begin
        return "???";
    end
endfunction

`define BSIM;

module mkTestRawEmuCore(Empty);
    let core <- mkEmuCore;
    
    // 直接驱动AXI-Lite Slave接口
    // 定义测试状态
    Reg#(Bool) arValid <- mkReg(False);
    Reg#(Bit#(AXI_ADDR_WIDTH)) arAddr <- mkReg(0);
    Reg#(Bool) rReady <- mkReg(False);
    
    // 写通道状态
    Reg#(Bool) awValid <- mkReg(False);
    Reg#(Bit#(AXI_ADDR_WIDTH)) awAddr <- mkReg(0);
    Reg#(Bool) wValid <- mkReg(False);
    Reg#(Bit#(AXI_DATA_WIDTH)) wData <- mkReg(0);
    Reg#(Bit#(TDiv#(AXI_DATA_WIDTH, BYTE_WIDTH))) wStrb <- mkReg(0);
    Reg#(Bool) bReady <- mkReg(False);

    // 超时时间（单位：时钟周期）
    UInt#(32) timeoutCycles = 1000000;

    //发包计数
    Reg#(UInt#(32)) sendCount <- mkReg(0);
    Reg#(UInt#(32)) cycleCount <- mkReg(0);

    // 初始化索引
    Reg#(UInt#(32)) initIdx <- mkReg(0);
    // 初始化完成标志
    Reg#(Bool) initialized <- mkReg(False);

    // ==================== 时钟计数 ====================
    rule updateclock;
        cycleCount <= cycleCount + 1;
    endrule

    // 确保所有AXI-Lite Slave接口方法在每个时钟周期都被驱动
    // 驱动写地址通道
    rule driveWriteAddrChannel;
        core.dmaAxiLiteSlave.wrSlave.awValidData(awValid, awAddr, 0);
    endrule
    
    // 驱动写数据通道
    rule driveWriteDataChannel;
        core.dmaAxiLiteSlave.wrSlave.wValidData(wValid, wData, wStrb);
    endrule
    
    // 驱动写响应通道
    rule driveWriteRespChannel;
        core.dmaAxiLiteSlave.wrSlave.bReady(bReady);
    endrule
    
    // 驱动读地址通道
    rule driveReadAddrChannel;
        core.dmaAxiLiteSlave.rdSlave.arValidData(arValid, arAddr, 0);
    endrule
    
    // 驱动读数据通道
    rule driveReadDataChannel;
        core.dmaAxiLiteSlave.rdSlave.rReady(rReady);
    endrule
    
    // 超时检测规则
    rule checkTimeout;
        if (cycleCount >= timeoutCycles) begin
            $display("[Per_Cfg Test] Timeout reached after ? cycles!");
            $display("[Per_Cfg Test] Test summary:");
            $display("[Per_Cfg Test] Stopping simulation due to timeout...");
            $finish(); // 超时后停止模拟
        end
    endrule

    // ==================== 节点初始化 ====================
    // 初始化BRAM规则
    rule initializeBRAM (!initialized && cycleCount % (10) == 1);
        if (initIdx <  (1<<14 -1) ) begin
            let percfg = getEmptyPerCfg;
            percfg.perIn  = truncate(initIdx);
            percfg.perOut =0;
            let bridgeTag = getEmptyBridgeTag();
            bridgeTag.control = 1;
            bridgeTag.notUsed = 1;
            AxiStream#(KEEP_WIDTH, TUSER_WIDTH) axiPkt = AxiStream{
                tData: zeroExtend(pack(tuple2(percfg,bridgeTag))),
                tKeep: '1,      // 所有字节有效
                tLast: True,     // 假设每个MAC事件对应一个AXI包
                tUser: 0
            };
            // core.tx.put(axiPkt);
            // cfgbridge.chanTxSrv.request.put(chancfg);
            initIdx <= initIdx + 1;
            // $display("Initializing node %0d with distance %0d", initIdx, distance);
        end else begin
            initialized <= True;
            $display("BRAM initialization completed");
            // $display("end");
            // $finish();
        end
    endrule

        // 简单的数据包发送规则
    rule sendPacket if (sendCount < 10 && cycleCount % 100000 == 0); // 只发送10个数据包
        // 创建一个简单的MAC事件
        MacEvent txReq = getEmptyMacEvent;
        txReq.srcMacId = 1;  // 源节点ID
        txReq.dstMacId = 0;  // 目标节点ID
        txReq.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
        txReq.mpduDigest.length = 1490;  // 数据包长度
        txReq.rfParam.power = 60*32;//1920
        txReq.rfParam.mcs = 0;
        txReq.mpduDigest.duration = 2164;
        // 创建AXI Stream数据包
        let bridgeTag = getEmptyBridgeTag();
        AxiStream#(KEEP_WIDTH, TUSER_WIDTH) axiPkt = AxiStream{
            tData: zeroExtend(pack(tuple2(txReq, bridgeTag))),
            tKeep: '1,      // 所有字节有效
            tLast: True,     // 这是数据包的最后一部分
            tUser: 0
        };
        
        // 发送数据包
        core.tx.put(axiPkt);
        $display("Sent packet %d from node %d to node %d", sendCount, txReq.srcMacId, txReq.dstMacId);
        
        // 更新发送计数
        sendCount <= sendCount + 1;
    endrule
    
    // 简单的数据包接收规则
    Reg#(UInt#(32)) recvCount <- mkReg(0);
    rule recvPacket;
        // 接收数据包
        let rxpkt <- core.rx.get;
        
        // 解析数据包
        MacEvent rxReq = unpack(truncate(rxpkt.tData));
        
        // 打印接收信息
        $display("Received packet %d from node %d", recvCount, rxReq.srcMacId);
        
        // 更新接收计数
        recvCount <= recvCount + 1;
    endrule

endmodule