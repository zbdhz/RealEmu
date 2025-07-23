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
typedef 100 TestNum;


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
    $display("rfParam: power = %0d, mcs = %0d", phy_event.rfParam.power, phy_event.rfParam.mcs);
    // $display("ppduLen: %0d", phy_event.ppduLen);
    // $display("mpduDigest: frameType = %0d, frameSubType = %0d, duration = %0d, length = %0d, cacheAddr = %0h", phy_event.mpduDigest.frameType, phy_event.mpduDigest.frameSubType, phy_event.mpduDigest.duration, phy_event.mpduDigest.length, phy_event.mpduDigest.cacheAddr);
endfunction

module mkTestLogDistanceGainLossModel(Empty);

    //计时器
    Reg#(UInt#(64)) cycleCount <- mkReg(0);
    //接收数据包索引
    Reg#(UInt#(16)) pktIdx <- mkReg(0);

    // DUT: Channel 模块
    let dut <- mkGainLossModelLogDistance("bram_one.txt");

    // 模拟接收数据包
    rule recvPkt_local (cycleCount % fromInteger(valueOf(Recv_delta_time)) == fromInteger(valueOf(Recv_time)));
        let txReq = getEmptyPhyEvent();
        dut.phyRxMetaSrv.request.put(txReq);
        pktIdx <= pktIdx + 1;
        $display("Recv pkt id:%d",pktIdx+1);
    endrule

    //处理数据包
    rule recvPkt_process;
        let rxReq <- dut.phyRxClt.request.get;
        printPhyEvent(rxReq);
        $display("Recv pkt process sucess");
        // dut.phyRxClt.response.put(PhyRxResp{});
    endrule

    //仿真进程控制
    rule updateclock;
        cycleCount <= cycleCount + 1;
    endrule

    // 响应读取
    rule handshake0;
        let resp <- dut.phyRxMetaSrv.response.get;
    endrule

     // 输出统计信息
    rule printStats (cycleCount % fromInteger(valueOf(Recv_delta_time)) == fromInteger(valueOf(Print_time)) && pktIdx == fromInteger(valueOf(TestNum)));
        $finish();
    endrule
endmodule