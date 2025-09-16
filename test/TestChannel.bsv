import ClientServer::*;
import GetPut::*;
import FIFO::*;
import Randomizable::*;
import BRAM::*;
import Vector::*;

import Channel::*;
import ROM::*;
import Types::*;
import PrimUtils::*;

// 配置参数
typedef 15000 Recv_delta_time;
typedef 1000 Recv_time;
typedef 12000 Print_time;
typedef 300 TestNum;
typedef 1024 ALL_Nodes;

function PhyEvent getEmptyPhyEvent();
        return PhyEvent {
            srcPhyId: 0,
            dstPhyId: 0,
            rfParam: RfParam { power: 2000, mcs: 0 },
            ppduLen: 0,
            mpduDigest: MpduDigest {
                frameType: 0,
                frameSubType: 0,
                duration: 0,
                length: 0,
                cacheAddr: 0
            }
        };
endfunction

function Action printPhyEvent(PhyEvent phy_event);
    // $display("srcPhyId: %0d", phy_event.srcPhyId);
    // $display("dstPhyId: %0d", phy_event.dstPhyId);
    // $display("rfParam: power = %0d, mcs = %0d", phy_event.rfParam.power, phy_event.rfParam.mcs);
    // $display("ppduLen: %0d", phy_event.ppduLen);
    // $display("mpduDigest: frameType = %0d, frameSubType = %0d, duration = %0d, length = %0d, cacheAddr = %0h", phy_event.mpduDigest.frameType, phy_event.mpduDigest.frameSubType, phy_event.mpduDigest.duration, phy_event.mpduDigest.length, phy_event.mpduDigest.cacheAddr);
    $display("srcPhyId=%0d, dstPhyId=%0d, power=%0d, mcs=%0d, ppduLen=%0d, frameType=%0d, frameSubType=%0d, duration=%0d, scalength=%0d, cacheAddr=%0h",
         phy_event.srcPhyId, phy_event.dstPhyId,
         phy_event.rfParam.power, phy_event.rfParam.mcs,
         phy_event.ppduLen,
         phy_event.mpduDigest.frameType, phy_event.mpduDigest.frameSubType,
         phy_event.mpduDigest.duration, phy_event.mpduDigest.length,
         phy_event.mpduDigest.cacheAddr);
endfunction

module mkTestLogDistanceGainLossModel(Empty);

    //计时器
    Reg#(UInt#(64)) cycleCount <- mkReg(0);
    //接收数据包索引
    Reg#(UInt#(16)) pktIdx <- mkReg(0);
    
    // 初始化索引
    Reg#(UInt#(32)) initIdx <- mkReg(0);
    // 初始化完成标志
    Reg#(Bool) initialized <- mkReg(False);

    // DUT: Channel 模块
    // let dut <- mkGainLossModelLogDistance("bram_sequence_1024.txt");
    let dut <- mkGainLossModelLogDistance;

    // 初始化BRAM规则
    rule initializeBRAM (!initialized);
        if (initIdx < fromInteger(valueOf(ALL_Nodes))) begin
            // 为每个节点设置距离值，这里使用简单的计算方式
            // 
            let distance = (initIdx < 256) ? 
                          (1 + initIdx ) : 
                          100;
                        // 使用BRAMRequest结构体发送写请求
            // let bramReq = BRAMRequest {
            //     write: True,
            //     responseOnWrite: False,
            //     address: truncate(pack(initIdx)),
            //     datain: truncate(pack(distance))
            // };
            let chancfg = getEmptyChannelCfg;
            chancfg.dstPhyId = truncate(pack(initIdx));
            chancfg.distance = truncate(pack(distance));
            dut.chanTxSrv.request.put(chancfg);
            // BRAMRequest{              // 构造一个 BRAMRequest 类型的结构体
            //     write: iswrite,           // True:写    False:读
            //     responseOnWrite: False,   // 不产生写响应
            //     address: addr,            // 读写地址
            //     datain: wdata             // 写入数据，当 iswrite=False 时，无所谓是什么
            // }
            initIdx <= initIdx + 1;
            $display("Initializing node %0d with distance %0d", initIdx, distance);
        end else begin
            initialized <= True;
            $display("BRAM initialization completed");
        end
    endrule

    // 模拟接收数据包
    rule recvPkt_local (initialized && cycleCount % fromInteger(valueOf(Recv_delta_time)) == fromInteger(valueOf(Recv_time)));
        let txReq = getEmptyPhyEvent();
        txReq.srcPhyId = truncate(pack(pktIdx));
        dut.channel.phyRxMetaSrv.request.put(txReq);
        pktIdx <= pktIdx + 1;
        $display("\nRecv pkt id:%d",pktIdx+1);
    endrule

    //处理数据包
    rule recvPkt_process (initialized);
        let rxReq <- dut.channel.phyRxClt.request.get;
        printPhyEvent(rxReq);
        // $display("Recv pkt process sucess");
        // dut.phyRxClt.response.put(PhyRxResp{});
    endrule

    //仿真进程控制
    rule updateclock;
        cycleCount <= cycleCount + 1;
    endrule

    // 响应读取
    rule handshake0;
        let resp1 <- dut.channel.phyRxMetaSrv.response.get;
    endrule

    // 配置握手
    rule handshake1;
        let resp2 <- dut.chanTxSrv.response.get;
    endrule

     // 输出统计信息
    rule printStats (cycleCount % fromInteger(valueOf(Recv_delta_time)) == fromInteger(valueOf(Print_time)) && pktIdx == fromInteger(valueOf(TestNum)));
        $finish();
    endrule
endmodule

// module mkTestLogDistanceGainLossModel(Empty);

//     //计时器
//     Reg#(UInt#(64)) cycleCount <- mkReg(0);
//     //接收数据包索引
//     Reg#(UInt#(16)) pktIdx <- mkReg(0);
    
//     // 初始化索引
//     Reg#(UInt#(32)) initIdx <- mkReg(0);
//     // 初始化完成标志
//     Reg#(Bool) initialized <- mkReg(False);

//     // DUT: Channel 模块
//     // let dut <- mkGainLossModelLogDistance("bram_sequence_1024.txt");
//     let dut <- mkGainLossModelLogDistance;

//     // 初始化BRAM规则
//     rule initializeBRAM (!initialized);
//         if (initIdx < fromInteger(valueOf(ALL_Nodes))) begin
//             // 为每个节点设置距离值，这里使用简单的计算方式
//             // 节点0-9: 100-1000米, 其余节点: 500米
//             let distance = (initIdx < 256) ? 
//                           (1 + initIdx ) : 
//                           100;
//                         // 使用BRAMRequest结构体发送写请求
//             let bramReq = BRAMRequest {
//                 write: True,
//                 responseOnWrite: False,
//                 address: truncate(pack(initIdx)),
//                 datain: truncate(pack(distance))
//             };
//             dut.configPort.request.put(bramReq);
//             // BRAMRequest{              // 构造一个 BRAMRequest 类型的结构体
//             //     write: iswrite,           // True:写    False:读
//             //     responseOnWrite: False,   // 不产生写响应
//             //     address: addr,            // 读写地址
//             //     datain: wdata             // 写入数据，当 iswrite=False 时，无所谓是什么
//             // }
//             initIdx <= initIdx + 1;
//             $display("Initializing node %0d with distance %0d", initIdx, distance);
//         end else begin
//             initialized <= True;
//             $display("BRAM initialization completed");
//         end
//     endrule

//     // 模拟接收数据包
//     rule recvPkt_local (initialized && cycleCount % fromInteger(valueOf(Recv_delta_time)) == fromInteger(valueOf(Recv_time)));
//         let txReq = getEmptyPhyEvent();
//         txReq.srcPhyId = truncate(pack(pktIdx));
//         dut.channel.phyRxMetaSrv.request.put(txReq);
//         pktIdx <= pktIdx + 1;
//         $display("\nRecv pkt id:%d",pktIdx+1);
//     endrule

//     //处理数据包
//     rule recvPkt_process (initialized);
//         let rxReq <- dut.channel.phyRxClt.request.get;
//         printPhyEvent(rxReq);
//         // $display("Recv pkt process sucess");
//         // dut.phyRxClt.response.put(PhyRxResp{});
//     endrule

//     //仿真进程控制
//     rule updateclock;
//         cycleCount <= cycleCount + 1;
//     endrule

//     // 响应读取
//     rule handshake0;
//         let resp <- dut.channel.phyRxMetaSrv.response.get;
//     endrule

//      // 输出统计信息
//     rule printStats (cycleCount % fromInteger(valueOf(Recv_delta_time)) == fromInteger(valueOf(Print_time)) && pktIdx == fromInteger(valueOf(TestNum)));
//         $finish();
//     endrule
// endmodule

// // 配置参数
// typedef 15000 Recv_delta_time;
// typedef 1000 Recv_time;
// typedef 12000 Print_time;
// typedef 128 TestNum;


// function PhyEvent getEmptyPhyEvent();
//         return PhyEvent {
//             srcPhyId: 0,
//             dstPhyId: 0,
//             rfParam: RfParam { power: 2000, mcs: 0 },
//             ppduLen: 0,
//             mpduDigest: MpduDigest {
//                 frameType: 0,
//                 frameSubType: 0,
//                 duration: 0,
//                 length: 0,
//                 cacheAddr: 0
//             }
//         };
// endfunction

// function Action printPhyEvent(PhyEvent phy_event);
//     // $display("srcPhyId: %0d", phy_event.srcPhyId);
//     // $display("dstPhyId: %0d", phy_event.dstPhyId);
//     // $display("rfParam: power = %0d, mcs = %0d", phy_event.rfParam.power, phy_event.rfParam.mcs);
//     // $display("ppduLen: %0d", phy_event.ppduLen);
//     // $display("mpduDigest: frameType = %0d, frameSubType = %0d, duration = %0d, length = %0d, cacheAddr = %0h", phy_event.mpduDigest.frameType, phy_event.mpduDigest.frameSubType, phy_event.mpduDigest.duration, phy_event.mpduDigest.length, phy_event.mpduDigest.cacheAddr);
//     $display("srcPhyId=%0d, dstPhyId=%0d, power=%0d, mcs=%0d, ppduLen=%0d, frameType=%0d, frameSubType=%0d, duration=%0d, length=%0d, cacheAddr=%0h",
//          phy_event.srcPhyId, phy_event.dstPhyId,
//          phy_event.rfParam.power, phy_event.rfParam.mcs,
//          phy_event.ppduLen,
//          phy_event.mpduDigest.frameType, phy_event.mpduDigest.frameSubType,
//          phy_event.mpduDigest.duration, phy_event.mpduDigest.length,
//          phy_event.mpduDigest.cacheAddr);
// endfunction

// module mkTestLogDistanceGainLossModel(Empty);

//     //计时器
//     Reg#(UInt#(64)) cycleCount <- mkReg(0);
//     //接收数据包索引
//     Reg#(UInt#(16)) pktIdx <- mkReg(0);

//     // DUT: Channel 模块
//     let dut <- mkGainLossModelLogDistance("bram_sequence_1024.txt");

//     // 模拟接收数据包
//     rule recvPkt_local (cycleCount % fromInteger(valueOf(Recv_delta_time)) == fromInteger(valueOf(Recv_time)));
//         let txReq = getEmptyPhyEvent();
//         txReq.srcPhyId = truncate(pack(pktIdx));
//         dut.phyRxMetaSrv.request.put(txReq);
//         pktIdx <= pktIdx + 1;
//         $display("\nRecv pkt id:%d",pktIdx+1);
//     endrule

//     //处理数据包
//     rule recvPkt_process;
//         let rxReq <- dut.phyRxClt.request.get;
//         printPhyEvent(rxReq);
//         // $display("Recv pkt process sucess");
//         // dut.phyRxClt.response.put(PhyRxResp{});
//     endrule

//     //仿真进程控制
//     rule updateclock;
//         cycleCount <= cycleCount + 1;
//     endrule

//     // 响应读取
//     rule handshake0;
//         let resp <- dut.phyRxMetaSrv.response.get;
//     endrule

//      // 输出统计信息
//     rule printStats (cycleCount % fromInteger(valueOf(Recv_delta_time)) == fromInteger(valueOf(Print_time)) && pktIdx == fromInteger(valueOf(TestNum)));
//         $finish();
//     endrule
// endmodule