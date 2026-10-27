//----------------------------------------------------------------------------------
//TreeDepth = 2
//----------------------------------------------------------------------------------
import Vector::*;
import ClientServer::*;
import GetPut::*;
import FIFO::*;
import FIFOF::*;
import RegFile::*;
import DReg::*;
import MathUtils::*;

import Types::*;

// typedef 64 NODE_NUM;

// typedef TLog#(NODE_NUM) NodeIdWidth;  // 10 bits
// typedef TDiv#(TLog#(NODE_NUM), TLog#(GROUP_SIZE)) TreeDepth;  // log32(1024)=2

typedef enum {MuxBegin, MuxEnd} MuxState deriving (Bits, Eq);

// 先广播更早开始的空口事件，保持干扰时间线的顺序。合法帧远小于半个回绕周期；
// 同时开始或旧测试未带时间时，保留原来的高编号优先作为稳定的平局规则。
function Bool airNoLater(PhyEvent candidate, PhyEvent current);
    Bool choose = True;
    if (candidate.airTimeValid && current.airTimeValid) begin
        UInt#(32) delta = candidate.airStarted - current.airStarted;
        choose = delta == 0 || delta >= 'h80000000;
    end
    return choose;
endfunction

interface ArbiterIFC;
    interface Vector#(NODE_NUM, PhySrv)  phyRxMetaSrv;  // 连接所有节点的phyTxMetaClt
    interface Vector#(NODE_NUM, PhyClt)  phyTxMetaClt;  // 连接所有节点的phyRxMetaSrv
endinterface

(* synthesize *)
module mkArbiter(ArbiterIFC);
    ///////////////////////////////////////////////////////////////////////////
    // 接口FIFO
    ///////////////////////////////////////////////////////////////////////////
    // Vector#(NODE_NUM, FIFOF#(PhyEvent))     txReqQs  <- replicateM(mkGFIFOF(False, True));        // 保护压入，不保护弹出
    Vector#(NODE_NUM, FIFOF#(PhyEvent))     txReqQs  <- replicateM(mkFIFOF);
    Vector#(NODE_NUM, FIFOF#(GenericResp))  txRespQs <- replicateM(mkFIFOF);
    Vector#(NODE_NUM, FIFOF#(PhyEvent))     rxReqQs  <- replicateM(mkFIFOF);
    Vector#(NODE_NUM, FIFOF#(GenericResp))  rxRespQs <- replicateM(mkFIFOF);

    ///////////////////////////////////////////////////////////////////////////
    // 轮询控制逻辑（保持原始结构）
    ///////////////////////////////////////////////////////////////////////////
    // C02: 广播事件保留到全部接收队列接受；单节点背压不能吃掉 valid。
    FIFOF#(PhyEvent) broadcastQ <- mkFIFOF;

    ///////////////////////////////////////////////////////////////////////////
    // 32叉树聚合逻辑
    ///////////////////////////////////////////////////////////////////////////
    Reg#(MuxState) muxState <- mkReg(MuxBegin);
    Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(PhyId))    phyIdRegs  <- replicateM(mkReg(0));
    Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(Bool))     validRegs1 <- replicateM(mkReg(False));
    Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(PhyEvent)) eventRegs1 <- replicateM(mkReg(getEmptyPhyEvent));

    // Level 1 MUX（32节点→1节点）
    rule muxBegin if (muxState == MuxBegin);
        Bool valid = False;
        for (Integer g = 0; g < valueOf(TDiv#(NODE_NUM, GROUP_SIZE)); g = g + 1) begin
            Bool groupValid = False;
            Integer groupId = 0;
            PhyEvent groupEvent = getEmptyPhyEvent;
            
            // 扫描32个子节点
            for (Integer i = 0; i < valueOf(GROUP_SIZE); i = i + 1) begin
                let nodeId = g * valueOf(GROUP_SIZE) + i;
                if (txReqQs[nodeId].notEmpty) begin
                    let phyTxReq = txReqQs[nodeId].first;
                    if (!groupValid || airNoLater(phyTxReq, groupEvent)) begin
                        groupValid = True;
                        groupEvent = phyTxReq;
                        groupId = nodeId;
                    end
                    //$display("%d",nodeId);
                end
            end
            validRegs1[g] <= groupValid;
            eventRegs1[g] <= groupEvent;
            phyIdRegs[g] <= fromInteger(groupId); 
            if(groupValid)begin
                valid = groupValid;  // 至少有一个组有效
            end
        end
        if(valid)begin
            muxState <= MuxEnd;  // 没有有效事件，直接结束
        end 
    endrule

    // Level 2 MUX（32组→1个全局）
    rule muxEnd if (muxState == MuxEnd);
        PhyId selectId = 0;  // 用于记录物理ID
        Bool finalValid = False;
        PhyEvent finalEvent = getEmptyPhyEvent;
        
        for (Integer g = 0; g < valueOf(TDiv#(NODE_NUM, GROUP_SIZE)); g = g + 1) begin
            if (validRegs1[g] && (!finalValid || airNoLater(eventRegs1[g], finalEvent))) begin
                finalValid = True;
                finalEvent = eventRegs1[g];  // 取最后一个有效事件
                selectId = phyIdRegs[g];  // 记录物理ID
            end
        end

        if (finalValid) broadcastQ.enq(finalEvent);
        muxState <= MuxBegin;
        if(finalValid && txReqQs[selectId].notEmpty)begin
            txReqQs[selectId].deq;
            txRespQs[selectId].enq(GenericResp{});
        end
    endrule

    ///////////////////////////////////////////////////////////////////////////
    // 32叉树广播流水线
    ///////////////////////////////////////////////////////////////////////////

    rule finalBroadcast;
        let evt = broadcastQ.first;
        for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
            if (evt.srcPhyId != fromInteger(i)) rxReqQs[i].enq(evt);
        end
        broadcastQ.deq;
    endrule

    for(Integer i = 0; i < valueOf(NODE_NUM); i = i + 1)begin
        rule handshakeRx;
            rxRespQs[i].deq;
        endrule
    end

    ///////////////////////////////////////////////////////////////////////////
    // 接口连接
    ///////////////////////////////////////////////////////////////////////////
    Vector#(NODE_NUM, PhySrv) rxMetaSrv;
    Vector#(NODE_NUM, PhyClt) txMetaClt;
    
    for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
        rxMetaSrv[i] = toGPServer(txReqQs[i], txRespQs[i]);
        txMetaClt[i] = toGPClient(rxReqQs[i], rxRespQs[i]);
    end

    interface phyRxMetaSrv = rxMetaSrv;
    interface phyTxMetaClt = txMetaClt;
endmodule
