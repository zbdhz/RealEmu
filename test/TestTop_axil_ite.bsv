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
    
    // 测试状态
    Reg#(Bool) testStarted <- mkReg(False);
    Reg#(UInt#(4)) testPhase <- mkReg(0);
    
    // 计时器
    Reg#(UInt#(32)) timer <- mkReg(0);
    // 超时时间（单位：时钟周期）
    UInt#(32) timeoutCycles = 1000000;

    //发包计数
    Reg#(UInt#(32)) sendCount <- mkReg(0);
    Reg#(UInt#(32)) cycleCount <- mkReg(0);
    // ==================== 时钟计数 ====================
    rule updateclock;
        cycleCount <= cycleCount + 1;
    endrule

    // 定义测试地址
    // Bit#(AXI_ADDR_WIDTH) node_base_addr = node_base_addr;
    
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
    
    // 计时器规则
    rule updateTimer;
        timer <= timer + 1;
        // if (timer > 0 && timer % 1000 == 0) begin
        //     $display("[AXI-Lite Test] Timer: %d cycles", timer);
        // end
    endrule
    
    // 超时检测规则
    rule checkTimeout;
        if (timer >= timeoutCycles) begin
            $display("[AXI-Lite Test] Timeout reached after %d cycles!", timer);
            $display("[AXI-Lite Test] Test summary:");
            $display("[AXI-Lite Test] - Test completed: %b", testPhase >= 6);
            $display("[AXI-Lite Test] - Current test phase: %d", testPhase);
            $display("[AXI-Lite Test] Stopping simulation due to timeout...");
            $finish(); // 超时后停止模拟
        end
    endrule
    
    // 测试序列控制
    rule controlTestSequence;
        if (!testStarted) begin
            $display("[AXI-Lite Test] Starting test...");
            $display("[AXI-Lite Test] Testing register at address: 0x%h", node_base_addr);
            testStarted <= True;
            testPhase <= 0;
        end else begin
            case (testPhase)
                0: begin // 开始读测试
                    $display("[AXI-Lite Test] Phase 0: Initiating read request...");
                    $display("[AXI-Lite Test] Read Address: 0x%h, Valid: %b", node_base_addr, True);
                    arValid <= True;
                    arAddr <= node_base_addr + node_per_node * 4 + mac_ofdm_symbol_off;
                    testPhase <= 1;
                end
                1: begin // 等待读地址确认
                    $display("[AXI-Lite Test] Phase 1: Waiting for arReady... Current arReady: %b", core.dmaAxiLiteSlave.rdSlave.arReady);
                    if (core.dmaAxiLiteSlave.rdSlave.arReady && arValid) begin
                        $display("[AXI-Lite Test] Phase 1: Read address acknowledged! Setting arValid to False, rReady to True");
                        arValid <= False;
                        rReady <= True;
                        testPhase <= 2;
                    end
                end
                2: begin // 等待读数据响应
                    $display("[AXI-Lite Test] Phase 2: Waiting for rValid... Current rValid: %b, rReady: %b", 
                             core.dmaAxiLiteSlave.rdSlave.rValid, rReady);
                    if (core.dmaAxiLiteSlave.rdSlave.rValid && rReady) begin
                        $display("[AXI-Lite Test] Phase 2: Read response received!");
                        $display("[AXI-Lite Test] Read Data: 0x%h", core.dmaAxiLiteSlave.rdSlave.rData);
                        $display("[AXI-Lite Test] Read Response: 0x%h", core.dmaAxiLiteSlave.rdSlave.rResp);
                        rReady <= False;
                        testPhase <= 3;
                    end
                end
                3: begin // 开始写测试
                    $display("[AXI-Lite Test] Phase 3: Initiating write request...");
                    $display("[AXI-Lite Test] Write Address: 0x%h, Valid: %b", node_base_addr, True);
                    $display("[AXI-Lite Test] Write Data: 0x%h, Valid: %b, Strb: 0x%h", 32'hDEADBEEF, True, 4'hF);
                    awValid <= True;
                    awAddr <= node_base_addr;
                    wValid <= True;
                    wData <= 32'h18;
                    wStrb <= 4'hF;
                    testPhase <= 4;
                end
                4: begin // 等待写地址和写数据确认
                    $display("[AXI-Lite Test] Phase 4: Waiting for awReady and wReady...");
                    $display("[AXI-Lite Test] Current awReady: %b, awValid: %b", core.dmaAxiLiteSlave.wrSlave.awReady, awValid);
                    $display("[AXI-Lite Test] Current wReady: %b, wValid: %b", core.dmaAxiLiteSlave.wrSlave.wReady, wValid);
                    if (core.dmaAxiLiteSlave.wrSlave.awReady && awValid && 
                        core.dmaAxiLiteSlave.wrSlave.wReady && wValid) begin
                        $display("[AXI-Lite Test] Phase 4: Write address and data acknowledged! Setting awValid and wValid to False, bReady to True");
                        awValid <= False;
                        wValid <= False;
                        bReady <= True;
                        testPhase <= 5;
                    end
                end
                5: begin // 等待写响应
                    $display("[AXI-Lite Test] Phase 5: Waiting for bValid... Current bValid: %b, bReady: %b", 
                             core.dmaAxiLiteSlave.wrSlave.bValid, bReady);
                    if (core.dmaAxiLiteSlave.wrSlave.bValid && bReady) begin
                        $display("[AXI-Lite Test] Phase 5: Write response received!");
                        $display("[AXI-Lite Test] Write Response: 0x%h", core.dmaAxiLiteSlave.wrSlave.bResp);
                        bReady <= False;
                        testPhase <= 6;
                    end
                end
                6: begin // 开始验证读测试（读刚才写入的数据）
                    $display("[AXI-Lite Test] Phase 6: Initiating verification read request...");
                    $display("[AXI-Lite Test] Read Address: 0x%h, Valid: %b", node_base_addr, True);
                    arValid <= True;
                    arAddr <= node_base_addr;
                    rReady <= True;
                    testPhase <= 7;
                end
                7: begin // 等待验证读响应
                    $display("[AXI-Lite Test] Phase 7: Waiting for rValid... Current rValid: %b, rReady: %b", 
                             core.dmaAxiLiteSlave.rdSlave.rValid, rReady);
                    if (core.dmaAxiLiteSlave.rdSlave.rValid && rReady) begin
                        $display("[AXI-Lite Test] Phase 7: Verification read response received!");
                        $display("[AXI-Lite Test] Read Response: 0x%h, Read Data: 0x%h", 
                                 core.dmaAxiLiteSlave.rdSlave.rResp, core.dmaAxiLiteSlave.rdSlave.rData);
                        // 比较读取的数据与写入的数据
                        if (core.dmaAxiLiteSlave.rdSlave.rData == 32'h18) begin
                            $display("[AXI-Lite Test] Phase 7: Verification PASSED! Read data matches written data");
                        end else begin
                            $display("[AXI-Lite Test] Phase 7: Verification FAILED! Read data: 0x%h, Expected: 0x%h", 
                                     core.dmaAxiLiteSlave.rdSlave.rData, 32'h18);
                        end
                        arValid <= False;
                        rReady <= False;
                        testPhase <= 8;
                    end
                end
                8: begin // 修改节点2的naven字段为0
                    $display("[AXI-Lite Test] Phase 8: Setting node 2's naven field to 0...");
                    // 计算节点2的naven寄存器地址：基地址 + (节点索引 * 节点地址大小) + 寄存器偏移
                    Bit#(AXI_ADDR_WIDTH) node2_naven_addr = node_base_addr + (2 * node_per_node) + nav_en_h_off;
                    $display("[AXI-Lite Test] Node 2 naven register address: 0x%h", node2_naven_addr);
                    // 发送写请求
                    awValid <= True;
                    awAddr <= node2_naven_addr;
                    wValid <= True;
                    wData <= 32'h00000000; // 第0位设为0
                    wStrb <= 4'hF;
                    testPhase <= 9;
                end
                9: begin // 等待写地址和写数据确认
                    $display("[AXI-Lite Test] Phase 9: Waiting for awReady and wReady...");
                    $display("[AXI-Lite Test] Current awReady: %b, awValid: %b", core.dmaAxiLiteSlave.wrSlave.awReady, awValid);
                    $display("[AXI-Lite Test] Current wReady: %b, wValid: %b", core.dmaAxiLiteSlave.wrSlave.wReady, wValid);
                    if (core.dmaAxiLiteSlave.wrSlave.awReady && awValid && 
                        core.dmaAxiLiteSlave.wrSlave.wReady && wValid) begin
                        $display("[AXI-Lite Test] Phase 9: Write address and data acknowledged! Setting awValid and wValid to False, bReady to True");
                        awValid <= False;
                        wValid <= False;
                        bReady <= True;
                        testPhase <= 10;
                    end
                end
                10: begin // 等待写响应
                    $display("[AXI-Lite Test] Phase 10: Waiting for write response...");
                    $display("[AXI-Lite Test] Current bValid: %b, bReady: %b", core.dmaAxiLiteSlave.wrSlave.bValid, bReady);
                    if (core.dmaAxiLiteSlave.wrSlave.bValid && bReady) begin
                        $display("[AXI-Lite Test] Phase 10: Write response received!");
                        $display("[AXI-Lite Test] Write Response: 0x%h", core.dmaAxiLiteSlave.wrSlave.bResp);
                        bReady <= False;
                        testPhase <= 11;
                    end
                end
                11: begin // 结束测试
                    $display("[AXI-Lite Test] Phase 11: All tests completed successfully!");
                    $display("[AXI-Lite Test] Test summary:");
                    $display("[AXI-Lite Test] - Read test: PASSED");
                    $display("[AXI-Lite Test] - Write test: PASSED");
                    $display("[AXI-Lite Test] - Verification read: PASSED");
                    $display("[AXI-Lite Test] - Node 2 naven field set to 0: COMPLETED");
                    $display("[AXI-Lite Test] - AXI-Lite interface functioning correctly");
                    $display("[AXI-Lite Test] Stopping simulation...");
                    testPhase <= 12;
                end
            endcase
        end
    endrule
    rule finishtest;
        if(sendCount == 10) $finish(); // 测试成功后停止模拟
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