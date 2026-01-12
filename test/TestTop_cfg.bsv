import GetPut::*;
import Connectable::*;
import ClientServer::*;
import Vector::*;
import StmtFSM::*;
import FIFO::*;

import Types::*;
import MacCore::*;
import CsmaUtils::*;
import PrimUtils::*;
import PhyCore::*;
import Channel::*;
import Arbitration::*;
import MacBridge::*;
import CfgBridge::*;

typedef 4 TEST_NODE_NUM;
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

// 辅助函数：创建带有参数的MacEvent
function MacEvent createMacEventWithParams(MacId srcId, MacId dstId, UInt#(16) length, Int#(12) power, Mcs mcs);
    MacEvent macEvent = getEmptyMacEvent;
    macEvent.srcMacId = srcId;
    macEvent.dstMacId = dstId;
    macEvent.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
    macEvent.mpduDigest.length = pack(length);
    macEvent.rfParam.power = power;
    macEvent.rfParam.mcs = mcs;
    return macEvent;
endfunction

function Action printmaccfg(MacConfig cfg);
    action
        $display("MacConfig:");
        $display("  slot: %0d", cfg.slot);
        $display("  sifs: %0d", cfg.sifs);
        $display("  difs: %0d", cfg.difs);
        $display("  eifs: %0d", cfg.eifs);
        $display("  sigTime: %0d", cfg.sigTime);
        $display("  ofdmSymbolTime: %0d", cfg.ofdmSymbolTime);
        $display("  maxNum: %0d", cfg.maxNum);
        $display("  phyDelayTime: %0d", cfg.phyDelayTime);
        $display("  timeout: %0d", cfg.timeout);
        $display("  cwMin: %0d", cfg.cwMin);
        $display("  cwMax: %0d", cfg.cwMax);
        $display("  rtsThreshold: %0d", cfg.rtsThreshold);
        $display("  retryLimit: %0d", cfg.retryLimit);
        $display("  navEn: %b", cfg.navEn);
        $display("  txopEn: %b", cfg.txopEn);
        $display("  filterEn: %b", cfg.filterEn);
    endaction
endfunction

// `define BSIM;

module mkTestTop_cfg(Empty);
    // ==================== 节点实例化 ====================
        Vector#(NODE_NUM, MacCore) macNodes <- genWithM(compose(mkMacDCF, fromInteger));
        Vector#(NODE_NUM, PhyCore) phyNodes <- genWithM(compose(mkPhyYansWifi, fromInteger));
        Vector#(NODE_NUM, GainLossModel_Ctrl) channels <- replicateM(mkGainLossModelLogDistance);

        MacBridgeIFC macbridge <- mkMacBridge;
        CfgBridgeIFC cfgbridge <- mkCfgBridge;
        ArbiterIFC pollController <- mkArbiter;

        Reg#(MacId) sendingNodes <- mkReg(1);     // 总接收包数
        // Reg#(UInt#(10)) sendingNodes <- mkReg(1);     // 总接收包数
        // 初始化索引
        Reg#(UInt#(32)) initIdx <- mkReg(0);
        // 初始化完成标志
        Reg#(Bool) initialized <- mkReg(False);
        // ==================== 控制寄存器 ====================
        Reg#(UInt#(64)) cycleCount <- mkReg(3);
        Reg#(UInt#(64)) totalReceived <- mkReg(0);     // 总接收包数
        Reg#(File) logFile <- mkReg(InvalidFile);     // 日志文件句柄

        // ==================== 初始化 ====================
        // rule printFilenamesOnce (cycleCount == 5);
        //     for(Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
        //         $display("Opening file: bram_%0d.txt", i);
        //     end
        // endrule

        rule initialize (cycleCount == 10);
            let fd <- $fopen("/home/emu/dev/RealEmu/scripts/throughout.txt", "w");
            logFile <= fd;
        endrule

        // ==================== 时钟计数 ====================
        rule updateclock;
            cycleCount <= cycleCount + 1;
        endrule

        // ==================== 节点连接 ====================
        for(Integer i=0; i<valueOf(NODE_NUM); i=i+1) begin
            mkConnection(macNodes[i].lowMacTxClt, phyNodes[i].lowMacTxSrv);
            mkConnection(macNodes[i].lowMacRxSrv, phyNodes[i].lowMacRxClt);
            mkConnection(phyNodes[i].phyTxClt, channels[i].channel.phyTxSrv);
            mkConnection(phyNodes[i].phyRxSrv, channels[i].channel.phyRxClt);
            mkConnection(pollController.phyTxMetaClt[i], channels[i].channel.phyRxMetaSrv);
            mkConnection(pollController.phyRxMetaSrv[i], channels[i].channel.phyTxMetaClt);

            mkConnection(macbridge.macTxClt[i], macNodes[i].highMacTxSrv);
            mkConnection(macbridge.macRxSrv[i], macNodes[i].highMacRxClt);
            
            mkConnection(cfgbridge.chanTxClt[i], channels[i].chanTxSrv);
        end
      
        rule updatePhyStatus;
            for (Integer i = 0; i < valueof(NODE_NUM); i = i + 1) begin
                let phyStatus <- phyNodes[i].getPhyStatus.get();
                macNodes[i].phyStatus.put(phyStatus);
            end
        endrule

        // 初始化BRAM规则
        rule initializeBRAM (!initialized);
            if (initIdx < fromInteger(valueOf(NODE_NUM))) begin
                // 为每个节点设置距离值，这里使用简单的计算方式
                let distance = (initIdx < 256) ? 
                            1*(1 + initIdx ) : 
                            100;

                let chancfg = getEmptyChannelCfg;
                chancfg.srcPhyId = truncate(pack(initIdx));
                chancfg.dstPhyId = 0;
                chancfg.distance = truncate(pack(distance));
                cfgbridge.chanTxSrv.request.put(chancfg);
                initIdx <= initIdx + 1;
                $display("Initializing node %0d with distance %0d", initIdx, distance);
            end else begin
                initialized <= True;
                $display("BRAM initialization completed");
            end
        endrule

        rule handshake_macbridge;
            let resp_macbridge <- macbridge.pcieTxSrv.response.get;
        endrule

        rule handshake_cfgbridge;
            let resp_cfgbridge <- cfgbridge.chanTxSrv.response.get;
        endrule

        // ==================== MAC配置测试 ====================
        // 使用StmtFSM编写测试流程
        Stmt testMacConfig = seq
            // 等待初始化完成
            while (!initialized) seq
                $display("Waiting for initialization...");
                delay(10);
            endseq
            
            $display("\n=== Starting MAC Configuration Test ===");
            
            // 1. 读取重传次数参数
            action
                // 在action块中，使用let表达式创建并初始化结构体
                RegAccessReq req;
                req.writeEnable = False;
                req.regOffset = mac_retry_limit_off;
                req.writeData = 0;
                macNodes[0].macRegSrv.request.put(req);
                $display("[TEST] Reading retry limit...");
            endaction
            
            // 2. 接收重传次数参数响应
            action
                RegAccessResp resp <- macNodes[0].macRegSrv.response.get;
                $display("[TEST] Current retry limit: %0d", resp.readData);
            endaction
            
            // 3. 修改重传次数参数
            action
                RegAccessReq req;
                req.writeEnable = True;
                req.regOffset = mac_retry_limit_off;
                req.writeData = 5;  // 修改为重传5次
                macNodes[0].macRegSrv.request.put(req);
                $display("[TEST] Writing new retry limit: 5");
            endaction
            
            // 4. 接收写操作响应
            action
                RegAccessResp resp <- macNodes[0].macRegSrv.response.get;
                $display("[TEST] Write retry limit response received");
            endaction
            
            // 5. 再次读取重传次数参数，验证修改是否成功
            action
                RegAccessReq req;
                req.writeEnable = False;
                req.regOffset = mac_retry_limit_off;
                req.writeData = 0;
                macNodes[0].macRegSrv.request.put(req);
                $display("[TEST] Reading retry limit again...");
            endaction
            
            // 6. 接收验证响应
            action
                RegAccessResp resp <- macNodes[0].macRegSrv.response.get;
                $display("[TEST] New retry limit: %0d", resp.readData);
                if (resp.readData == 5) begin
                    $display("[TEST] PASS: Retry limit successfully changed!");
                end else begin
                    $display("[TEST] FAIL: Retry limit change failed!");
                end
            endaction
            
            // 7. 读取fifoin_count的值
            action
                RegAccessReq req;
                req.writeEnable = False;
                req.regOffset = mac_fifoin_count_off;
                req.writeData = 0;
                macNodes[1].macRegSrv.request.put(req);
                $display("[TEST] Reading fifoin_count...");
            endaction
            
            // 8. 接收fifoin_count响应
            action
                RegAccessResp resp <- macNodes[1].macRegSrv.response.get;
                $display("[TEST] Current fifoin_count: %0d", resp.readData);
            endaction
            
            // 9. 连续发送3个包
            $display("[TEST] Sending 3 packets...");
            // 使用Server接口的响应机制确保顺序执行
            seq
                // 发送第一个包
                action
                    let txReq = createMacEventWithParams(1, 0, 100, 40*32, 0);
                    macbridge.pcieTxSrv.request.put(txReq);
                    // macNodes[1].highMacTxSrv.request.put(txReq);
                    $display("[TEST] Sent packet 1 from node 1 to node 0");
                endaction
                // action
                //     let resp <- macNodes[1].highMacTxSrv.response.get;
                //     $display("[TEST] Received response for packet 1");
                // endaction
                
                // 发送第二个包
                action
                    let txReq = createMacEventWithParams(1, 0, 100, 40*32, 0);
                    macbridge.pcieTxSrv.request.put(txReq);
                    $display("[TEST] Sent packet 2 from node 1 to node 0");
                endaction
                // action
                //     let resp <- macNodes[1].highMacTxSrv.response.get;
                //     $display("[TEST] Received response for packet 2");
                // endaction
                
                // 发送第三个包
                action
                    let txReq = createMacEventWithParams(1, 0, 100, 40*32, 0);
                    macbridge.pcieTxSrv.request.put(txReq);
                    $display("[TEST] Sent packet 3 from node 1 to node 0");
                endaction
                // action
                //     let resp <- macNodes[1].highMacTxSrv.response.get;
                //     $display("[TEST] Received response for packet 3");
                // endaction
            endseq
            
            // // 10. 等待包进入队列
            delay(100000);
            
            // 11. 再次读取fifoin_count的值
            action
                RegAccessReq req;
                req.writeEnable = False;
                req.regOffset = mac_fifoin_count_off;
                req.writeData = 0;
                macNodes[1].macRegSrv.request.put(req);
                $display("[TEST] Reading fifoin_count after sending packets...");
            endaction
            
            // // 12. 接收fifoin_count响应并验证
            action
                RegAccessResp resp <- macNodes[1].macRegSrv.response.get;
                $display("[TEST] New fifoin_count: %0d", resp.readData);
                if (resp.readData > 0) begin
                    $display("[TEST] PASS: Packets successfully added to FIFO!");
                end else begin
                    $display("[TEST] FAIL: No packets in FIFO!");
                end
            endaction
            
            $display("\n=== MAC Configuration Test Completed ===");
            
            // ==================== PHY 配置测试 ==================== 
            $display("\n=== Starting PHY Configuration Test ===");
            
            // 1. 读取PHY FSM状态
            action
                RegAccessReq req;
                req.writeEnable = False;
                req.regOffset = phy_fsm_state_off;
                req.writeData = 0;
                phyNodes[1].phyRegSrv.request.put(req);
                $display("[TEST] Reading PHY FSM state...");
            endaction
            
            // 2. 接收PHY FSM状态响应
            action
                RegAccessResp resp <- phyNodes[1].phyRegSrv.response.get;
                $display("[TEST] Current PHY FSM state: %0d", resp.readData);
            endaction
            
            // 3. 读取PHY CCA忙状态
            action
                RegAccessReq req;
                req.writeEnable = False;
                req.regOffset = phy_cca_busy_off;
                req.writeData = 0;
                phyNodes[1].phyRegSrv.request.put(req);
                $display("[TEST] Reading PHY CCA busy state...");
            endaction
            
            // 4. 接收PHY CCA忙状态响应
            action
                RegAccessResp resp <- phyNodes[1].phyRegSrv.response.get;
                $display("[TEST] Current PHY CCA busy state: %b", resp.readData[0]);
            endaction
            
            // 5. 读取PHY RSSI (接收信号强度)
            action
                RegAccessReq req;
                req.writeEnable = False;
                req.regOffset = rx_power_dbm_off;
                req.writeData = 0;
                phyNodes[1].phyRegSrv.request.put(req);
                $display("[TEST] Reading PHY RSSI...");
            endaction
            
            // 6. 接收PHY RSSI响应
            action
                RegAccessResp resp <- phyNodes[1].phyRegSrv.response.get;
                $display("[TEST] Current PHY RSSI: %d", unpack(pack(resp.readData)[11:0]));
            endaction
            
            $display("\n=== PHY Configuration Test Completed ===");
        endseq;

        // 运行测试流程
        mkAutoFSM(testMacConfig);

endmodule