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

typedef TLog#(NODE_NUM) NodeIdWidth;  // 10 bits
typedef TDiv#(TLog#(NODE_NUM), TLog#(GROUP_SIZE)) TreeDepth;  // log32(1024)=2

typedef enum {MuxBegin, MuxEnd} MuxState deriving (Bits, Eq);

interface PollIFC;
    interface Vector#(NODE_NUM, PhySrv)  phyRxMetaSrv;  // 连接所有节点的phyTxMetaClt
    interface Vector#(NODE_NUM, PhyClt)  phyTxMetaClt;  // 连接所有节点的phyRxMetaSrv
endinterface

(* synthesize *)
module mkPoll(PollIFC);
    ///////////////////////////////////////////////////////////////////////////
    // 接口FIFO
    ///////////////////////////////////////////////////////////////////////////
    Vector#(NODE_NUM, FIFOF#(PhyEvent))     txReqQs  <- replicateM(mkGFIFOF(False, True));        // 保护压入，不保护弹出
    Vector#(NODE_NUM, FIFOF#(GenericResp))  txRespQs <- replicateM(mkFIFOF);
    Vector#(NODE_NUM, FIFOF#(PhyEvent))     rxReqQs  <- replicateM(mkFIFOF);
    Vector#(NODE_NUM, FIFOF#(GenericResp))  rxRespQs <- replicateM(mkFIFOF);

    ///////////////////////////////////////////////////////////////////////////
    // 轮询控制逻辑（保持原始结构）
    ///////////////////////////////////////////////////////////////////////////
    Reg#(Bool) pollValidReg <- mkReg(True);
    Reg#(UInt#(NodeIdWidth)) pollIdReg <- mkReg(0);
    Vector#(NODE_NUM, Reg#(Bool)) grandValidRegs <- replicateM(mkDReg(False));
    Vector#(NODE_NUM, Reg#(PhyEvent)) txEventRegs <- replicateM(mkDReg(getEmptyPhyEvent));

    Vector#(TreeDepth, Vector#(TDiv#(NODE_NUM, GROUP_SIZE), 
    Reg#(Tuple2#(Bool, PhyEvent)))) deMuxRegs <- replicateM(replicateM(mkDReg(tuple2(False, getEmptyPhyEvent))));

  
    rule poll if (pollValidReg);
        let current_id = pollIdReg;
        pollIdReg <= (current_id == fromInteger(valueOf(NODE_NUM)-1) ? 0 : current_id + 1);
        if (txReqQs[current_id].notEmpty) begin
            let phyTxReq = txReqQs[current_id].first;
            txReqQs[current_id].deq;
            txRespQs[current_id].enq(GenericResp{});

            grandValidRegs[current_id] <= True;
            txEventRegs[current_id] <= phyTxReq;
            pollValidReg <= False;
        end
    endrule

    ///////////////////////////////////////////////////////////////////////////
    // 32叉树聚合逻辑
    ///////////////////////////////////////////////////////////////////////////
    Reg#(MuxState) muxState <- mkReg(MuxBegin);
    Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(Bool))     validRegs1 <- replicateM(mkReg(False));
    Vector#(TDiv#(NODE_NUM, GROUP_SIZE), Reg#(PhyEvent)) eventRegs1 <- replicateM(mkReg(getEmptyPhyEvent));
    Reg#(Bool)     validRegs2 <- mkReg(False);
    Reg#(PhyEvent) eventRegs2 <- mkReg(getEmptyPhyEvent);

    // Level 1 MUX（32节点→1节点）
    rule muxLevel0 if (muxState == MuxBegin && !pollValidReg);
        for (Integer g = 0; g < valueOf(TDiv#(NODE_NUM, GROUP_SIZE)); g = g + 1) begin
            Bool group_valid = False;
            PhyEvent group_event = getEmptyPhyEvent;
            
            // 扫描32个子节点
            for (Integer i = 0; i < valueOf(GROUP_SIZE); i = i + 1) begin
                let node_id = g * valueOf(GROUP_SIZE) + i;
                if (grandValidRegs[node_id]) begin
                    group_valid = True;
                    group_event = txEventRegs[node_id];  // 取最后一个有效事件
                end
            end
            
            validRegs1[g] <= group_valid;
            eventRegs1[g] <= group_event;
        end
        muxState <= MuxEnd;
    endrule

    // Level 2 MUX（32组→1个全局）
    (* mutually_exclusive = "poll, muxEnd" *)  
    rule muxEnd if (muxState == MuxEnd);
        Bool final_valid = False;
        PhyEvent final_event = getEmptyPhyEvent;
        
        for (Integer g = 0; g < valueOf(TDiv#(NODE_NUM, GROUP_SIZE)); g = g + 1) begin
            if (validRegs1[g]) begin
                final_valid = True;
                final_event = eventRegs1[g];  // 取最后一个有效事件
            end
        end
        
        validRegs2 <= final_valid;
        eventRegs2 <= final_event;
        deMuxRegs[0][0] <= tuple2(final_valid, final_event);
        muxState <= MuxBegin;
        pollValidReg <= True;
    endrule

    ///////////////////////////////////////////////////////////////////////////
    // 32叉树广播流水线
    ///////////////////////////////////////////////////////////////////////////

    rule propagateDeMux;
        for (Integer lv = 0; lv < valueOf(TreeDepth)-1; lv = lv + 1) begin
            Integer next_lv = lv + 1;
            Integer gr = valueOf(GROUP_SIZE) ** fromInteger(lv);
            for (Integer g = 0; g < gr; g = g + 1) begin
                let {valid, txEvent} = deMuxRegs[lv][g];
                // 每个节点广播到32个子节点
                for (Integer sg = 0; sg < valueOf(GROUP_SIZE); sg = sg + 1) begin
                    deMuxRegs[next_lv][g*valueOf(GROUP_SIZE)+sg] <= tuple2(valid, txEvent);
                end
            end
        end
    endrule

    ///////////////////////////////////////////////////////////////////////////
    // 最终广播分发
    ///////////////////////////////////////////////////////////////////////////
    rule finalBroadcast;
        for (Integer g = 0; g < valueOf(GROUP_SIZE); g = g + 1) begin
            for (Integer gr = 0; gr < valueOf(GROUP_SIZE); gr = gr + 1) begin
                let index = g*valueOf(GROUP_SIZE) + gr;
                let {valid, txEvent} = deMuxRegs[valueOf(TreeDepth)-1][g];
                if (valid && (txEvent.srcPhyId != fromInteger(index))) begin
                    rxReqQs[index].enq(txEvent);
                end
            end
        end
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




////////////////////////////////////////////////////////////////////
//TreeDepth = 5
///////////////////////////////////////////////////////////////////

// import Vector::*;
// import ClientServer::*;
// import GetPut::*;
// import FIFO::*;
// import FIFOF::*;
// import RegFile::*;
// import DReg::*;
// import MathUtils::*;

// import Types::*;

// typedef 1024 NODE_NUM;
// typedef 4    GROUP_SIZE;  // 4叉树结构
// typedef TLog#(NODE_NUM) NodeIdWidth;  // 10 bits
// typedef 5 TreeDepth;  // log4(1024)=5

// // 增强状态机定义
// typedef enum {
//     Polling,        // 轮询状态
//     Aggregate1,     // 第1级聚合（1024→256）
//     Aggregate2,     // 第2级聚合（256→64）
//     Aggregate3,     // 第3级聚合（64→16）
//     Aggregate4,     // 第4级聚合（16→4）
//     Aggregate5,     // 第5级聚合（4→1）
// } MuxState deriving (Bits, Eq, FShow);

// interface PollIFC;
//     interface Vector#(NODE_NUM, PhySrv)  phyRxMetaSrv;
//     interface Vector#(NODE_NUM, PhyClt)  phyTxMetaClt;
//     method Bool isProcessing();
// endinterface

// (* synthesize *)
// module mkPoll(PollIFC);
//     ///////////////////////////////////////////////////////////////////////////
//     // 接口FIFO
//     ///////////////////////////////////////////////////////////////////////////
//     Vector#(NODE_NUM, FIFOF#(PhyEvent))     txReqQs  <- replicateM(mkGFIFOF1(False, True));        // 保护压入，不保护弹出
//     Vector#(NODE_NUM, FIFOF#(GenericResp))  txRespQs <- replicateM(mkFIFOF);
//     Vector#(NODE_NUM, FIFOF#(PhyEvent))     rxReqQs  <- replicateM(mkSizedFIFOF(10));
//     Vector#(NODE_NUM, FIFOF#(GenericResp))  rxRespQs <- replicateM(mkSizedFIFOF(10));

//     // 控制寄存器
//     Reg#(MuxState) muxState <- mkReg(Polling);
//     Reg#(UInt#(NodeIdWidth)) pollId <- mkReg(0);
    
//     // 分层事件寄存器
//     Vector#(TreeDepth, Vector#(TDiv#(NODE_NUM, GROUP_SIZE), 
//         Reg#(Maybe#(PhyEvent)))) aggRegs <- replicateM(replicateM(mkReg(tagged Invalid)));

//     Vector#(TreeDepth, Vector#(TDiv#(NODE_NUM, GROUP_SIZE), 
//     Reg#(Tuple2#(Bool, PhyEvent)))) deMuxRegs <- replicateM(replicateM(mkDReg(tuple2(False, getEmptyPhyEvent))));

//     // 轮询规则（优先级最高）
//     (* preempts = "do_poll, aggregate_*" *)
//     rule do_poll if (muxState == Polling);
//         if (txReqQs[pollId].notEmpty) begin
//             let evt = txReqQs[pollId].first;
//             txReqQs[pollId].deq;
//             aggRegs[0][pollId] <= tagged Valid evt;
//             muxState <= Aggregate1;
//         end
//         pollId <= (pollId == fromInteger(valueOf(NODE_NUM)-1)) ? 0 : pollId + 1;
//     endrule

//     // 分层聚合规则 ----------------------------------------------------------
//     // 第1级聚合（4→1）
//     rule aggregate_1 if (muxState == Aggregate1);
//         for(Integer g=0; g<256; g=g+1) begin  // 1024/4=256组
//             Maybe#(PhyEvent) evt = tagged Invalid;
//             for(Integer i=0; i<4; i=i+1) begin
//                 if (isValid(aggRegs[0][g*4+i])) begin
//                     evt = aggRegs[0][g*4+i];
//                 end
//             end
//             aggRegs[1][g] <= evt;
//         end
//         muxState <= Aggregate2;
//     endrule

//     // 第2级聚合（256→64）
//     rule aggregate_2 if (muxState == Aggregate2);
//         for(Integer g=0; g<64; g=g+1) begin
//             Maybe#(PhyEvent) evt = tagged Invalid;
//             for(Integer i=0; i<4; i=i+1) begin
//                 if (isValid(aggRegs[1][g*4+i])) evt = aggRegs[1][g*4+i];
//             end
//             aggRegs[2][g] <= evt;
//         end
//         muxState <= Aggregate3;
//     endrule

//     // 第3级聚合（64→16）
//     rule aggregate_3 if (muxState == Aggregate3);
//         for(Integer g=0; g<16; g=g+1) begin
//             Maybe#(PhyEvent) evt = tagged Invalid;
//             for(Integer i=0; i<4; i=i+1) begin
//                 if (isValid(aggRegs[2][g*4+i])) evt = aggRegs[2][g*4+i];
//             end
//             aggRegs[3][g] <= evt;
//         end
//         muxState <= Aggregate4;
//     endrule

//     // 第4级聚合（16→4）
//     rule aggregate_4 if (muxState == Aggregate4);
//         for(Integer g=0; g<4; g=g+1) begin
//             Maybe#(PhyEvent) evt = tagged Invalid;
//             for(Integer i=0; i<4; i=i+1) begin
//                 if (isValid(aggRegs[3][g*4+i])) evt = aggRegs[3][g*4+i];
//             end
//             aggRegs[4][g] <= evt;
//         end
//         muxState <= Aggregate5;
//     endrule

//     // 第5级聚合（4→1）
//     rule aggregate_5 if (muxState == Aggregate5);
//         Maybe#(PhyEvent) finalEvt = tagged Invalid;
//         for(Integer g=0; g<4; g=g+1) begin
//             if (isValid(aggRegs[4][g])) finalEvt = aggRegs[4][g];
//         end
//         deMuxRegs[0][0] <= finalEvt;
//         muxState <=  Polling;
//     endrule


//     // 分层广播规则 ----------------------------------------------------------
//     // 第1级广播（1→4）
//     rule propagateDeMux;
//         for (Integer lv = 0; lv < valueOf(TreeDepth)-1; lv = lv + 1) begin
//             Integer next_lv = lv + 1;
//             Integer gr = valueOf(GROUP_SIZE) ** fromInteger(lv);
//             for (Integer g = 0; g < gr; g = g + 1) begin
//                 let {valid, txEvent} = deMuxRegs[lv][g];
//                 for (Integer sg = 0; sg < valueOf(GROUP_SIZE); sg = sg + 1) begin
//                     deMuxRegs[next_lv][g*valueOf(GROUP_SIZE)+sg] <= tuple2(valid, txEvent);
//                 end
//             end
//         end
//     endrule

//     ///////////////////////////////////////////////////////////////////////////
//     // 最终广播分发
//     ///////////////////////////////////////////////////////////////////////////
//     rule finalBroadcast;
//         for (Integer g = 0; g < valueOf(NODE_NUM); g = g + 1) begin
//             let {valid, txEvent} = deMuxRegs[valueOf(TreeDepth)-1][g / valueOf(GROUP_SIZE)];
//             if (valid && (txEvent.srcPhyId != fromInteger(g))) begin
//                 rxReqQs[g].enq(txEvent);
//             end
//         end
//     endrule


//     // 接口连接
//     Vector#(NODE_NUM, PhySrv) rxSrv;
//     Vector#(NODE_NUM, PhyClt) txClt;
//     for(Integer i=0; i<valueOf(NODE_NUM); i=i+1) begin
//         rxSrv[i] = toGPServer(txReqQs[i], txRespQs[i]);
//         txClt[i] = toGPClient(rxReqQs[i], rxRespQs[i]);
//     end

//     interface phyRxMetaSrv = rxSrv;
//     interface phyTxMetaClt = txClt;
// endmodule







//------------------------------------------
//8-2 for sim
//------------------------------------------

// import Vector::*;
// import ClientServer::*;
// import GetPut::*;
// import FIFO::*;
// import FIFOF::*;
// import RegFile::*;
// import DReg::*;
// import MathUtils::*;

// import Types::*;

// typedef TLog#(NodeNum) NodeIdWidth;

// typedef 3  TreeDepth;        // log2(1024)=10
// typedef enum {MuxBegin, MuxLevel1, MuxEnd} MuxState deriving (Bits, Eq);

// interface PollIFC;
//     interface Vector#(NodeNum, PhySrv)  phyRxMetaSrv;  // 连接所有节点的phyTxMetaClt
//     interface Vector#(NodeNum, PhyClt)  phyTxMetaClt;  // 连接所有节点的phyRxMetaSrv
// endinterface

// (* synthesize *)
// module mkPoll(PollIFC);
//     // 接口FIFO -----------------------------------------------------------
//     Vector#(NodeNum, FIFOF#(PhyEvent))     txReqQs  <- replicateM(mkGFIFOF1(False, True));        // 保护压入，不保护弹出
//     Vector#(NodeNum, FIFOF#(GenericResp))  txRespQs <- replicateM(mkFIFOF);
//     Vector#(NodeNum, FIFOF#(PhyEvent))     rxReqQs  <- replicateM(mkSizedFIFOF(10));
//     Vector#(NodeNum, FIFOF#(GenericResp))  rxRespQs <- replicateM(mkSizedFIFOF(10));


//     //poll
//     Reg#(Bool)  pollValidReg  <- mkReg(True);
//     Reg#(UInt#(NodeIdWidth)) pollIdReg <- mkReg(0);
//     Vector#(NodeNum, Reg#(Bool)) grandValidRegs <- replicateM(mkDReg(False));
//     Vector#(NodeNum, Reg#(PhyEvent)) txEventRegs <- replicateM(mkDReg(getEmptyPhyEvent));

    
//     rule poll if (pollValidReg);
//         let current_id = pollIdReg;
//         if (txReqQs[current_id].notEmpty) begin
//             let phyTxReq = txReqQs[current_id].first;
//             txReqQs[current_id].deq;
//             grandValidRegs[current_id] <= True;
//             txEventRegs[current_id] <= phyTxReq;
//             pollValidReg <= False;
//         end
//         pollIdReg <= (current_id == fromInteger(valueOf(NodeNum)-1))? 0 : current_id + 1;
//     endrule

//     //MUX
//     Reg#(MuxState) muxState <- mkReg(MuxBegin);
//     Vector#(TDiv#(NodeNum, TExp#(1)), Reg#(Bool))     validRegs1   <- replicateM(mkReg(False));
//     Vector#(TDiv#(NodeNum, TExp#(1)), Reg#(PhyEvent)) eventRegs1   <- replicateM(mkReg(getEmptyPhyEvent));

//     rule muxLevel0 if((muxState == MuxBegin) && (pollValidReg == False));
//         PhyId groups = fromInteger(valueOf(NodeNum))/2;
//         for (PhyId g = 0; g < groups; g = g + 1) begin
//             PhyId node0 = 2*g; PhyId node1 = 2*g+1;
//             validRegs1[g] <=  grandValidRegs[node0] || grandValidRegs[node1];
//             eventRegs1[g] <= (grandValidRegs[node0] ? txEventRegs[node0] : (grandValidRegs[node1] ? txEventRegs[node1] : getEmptyPhyEvent));
//         end
//         // 切换到下一阶段
//         muxState <= MuxLevel1;
//     endrule


//     Vector#(TDiv#(NodeNum, TExp#(2)), Reg#(Bool))     validRegs2   <- replicateM(mkReg(False));
//     Vector#(TDiv#(NodeNum, TExp#(2)), Reg#(PhyEvent)) eventRegs2   <- replicateM(mkReg(getEmptyPhyEvent));

//     rule muxLevel1 if(muxState == MuxLevel1);
//         PhyId groups = fromInteger(valueOf(NodeNum))/4;
//         for (PhyId g = 0; g < groups; g = g + 1) begin
//             PhyId node0 = 2*g; PhyId node1 = 2*g+1;
//             validRegs2[g] <=  validRegs1[node0] || validRegs1[node1];
//             eventRegs2[g] <= (validRegs1[node0] ? eventRegs1[node0] : (validRegs1[node1] ? eventRegs1[node1] : getEmptyPhyEvent));
//         end
//         // 切换到下一阶段
//         muxState <= MuxEnd;
//     endrule

//     Vector#(TreeDepth, Vector#(TDiv#(NodeNum, TExp#(1)), 
//     Reg#(Tuple2#(Bool, PhyEvent)))) deMuxRegs <- replicateM(replicateM(mkDReg(tuple2(False,getEmptyPhyEvent))));

//     rule muxLevel2 if((muxState == MuxEnd) && (pollValidReg == False));
//         let validReg       =  validRegs2[0] || validRegs2[1];
//         let grandEventReg  = (validRegs2[0] ? eventRegs2[0] : (validRegs2[1] ? eventRegs2[1] : getEmptyPhyEvent));
//         //启动广播流水线
//         deMuxRegs[0][0] <= tuple2(validReg, grandEventReg);
//         muxState <= MuxBegin;
//         pollValidReg <= True;
//     endrule


//     // 树状广播流水线 ------------------------------------------------------
//     rule propagatedeMux0;  // 非最终级
//         for(Integer lv=0; lv<valueOf(TreeDepth)-1; lv=lv+1) begin
//             Integer groups = (2**lv);
//             for(Integer g=0; g<groups; g=g+1) begin
//                 let {valid, phyTxReq} = deMuxRegs[lv][g];
                
//                 // 计算子组范围
//                 Integer child0 = 2*g;
//                 Integer child1 = 2*g+1;
                
//                 // 向两个子组广播
//                 deMuxRegs[lv+1][child0] <=  tuple2(valid, phyTxReq);
//                 deMuxRegs[lv+1][child1] <=  tuple2(valid, phyTxReq);
//             end
//         end
//     endrule

//     // 最终级广播处理 ------------------------------------------------------
//     rule finaldeMux;
//         Integer groups = valueOf(NodeNum)/2;
//         for(Integer g=0; g<groups; g=g+1) begin
//             let {valid, phyTxReq} = deMuxRegs[valueOf(TreeDepth)-1][g];
            
//             // 计算目标节点
//             Integer node0 = 2*g;
//             Integer node1 = 2*g+1;
            
//             // 写入接收队列（跳过源节点）
//             if(valid)begin
//                 if(phyTxReq.srcPhyId != fromInteger(node0)) 
//                     rxReqQs[node0].enq(phyTxReq);
//                 if(phyTxReq.srcPhyId != fromInteger(node1)) 
//                     rxReqQs[node1].enq(phyTxReq);
//             end
//         end
//     endrule

//     // 接口连接 -----------------------------------------------------------
//     Vector#(NodeNum, PhySrv) rxMetaSrv;
//     Vector#(NodeNum, PhyClt) txMetaClt;
    
//     for(Integer i=0; i<valueOf(NodeNum); i=i+1) begin
//         rxMetaSrv[i] = toGPServer(txReqQs[i], txRespQs[i]);
//         txMetaClt[i] = toGPClient(rxReqQs[i], rxRespQs[i]);
//     end

//     interface phyRxMetaSrv = rxMetaSrv;
//     interface phyTxMetaClt = txMetaClt;
// endmodule



