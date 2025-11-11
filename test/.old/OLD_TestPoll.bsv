import GetPut::*;
import Connectable::*;
import ClientServer::*;
import Vector::*;
import FIFO::*;
import MathUtils::*;
import BRAM::*;


import Types::*;
import Poll::*;
import Channel::*;

module mkTestPoll(Empty);
    //实例化仲裁器
    PollIFC poll <- mkPoll;

    // BRAM2Port#(PhyId, NodeDistance) distanceRam2 <- mkBRAM2Server(
    //     defaultValue
    //     // BRAM_Configure {                            
    //     //     memorySize   : 0,                       
    //     //     loadFormat   : None,     
    //     //     latency      : 2,                          
    //     //     outFIFODepth : 4,                          
    //     //     allowWriteResponseBypass : False           
    //     // }
    // );
    
    //创建节点模型
    //Vector#(NODE_NUM, GainLossModel) nodes <- replicateM(mkGainLossModelLogDistance);
    Vector#(NODE_NUM, GainLossModel) nodes <- replicateM(mkGainLossModelIdeal);
    
    //连接接口
    for(Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
        mkConnection(nodes[i].phyTxMetaClt, poll.phyRxMetaSrv[i]);
        mkConnection(poll.phyTxMetaClt[i], nodes[i].phyRxMetaSrv);
    end

    Reg#(UInt#(64)) cycleCount <- mkReg(0);

    rule updateclock;
        cycleCount <= cycleCount + 1;
    endrule


    // for(Integer g = 0; g < valueOf(GROUP_SIZE); g = g + 1)begin
    //     rule handshake0;
    //         let resp <- nodes[g].phyRxMetaSrv.response.get;
    //     endrule
    // end

    for(Integer g = 0; g < valueOf(NODE_NUM); g = g + 1)begin
        rule handshake1;
            let resp <- nodes[g].phyTxSrv.response.get;
        endrule
    end


    // 测试案例1：基础仲裁
    rule send1 if (cycleCount == fromInteger(10*valueOf(NODE_NUM)));
        $display("\nNode2 sends a packet");
        PhyEvent event2 = getEmptyPhyEvent();
        event2.srcPhyId = 2;
        nodes[2].phyTxSrv.request.put(event2);
    endrule

    rule send2 if (cycleCount == fromInteger(20*valueOf(NODE_NUM)));
        $display("\nNode0 and Node1 send a packet at the same time");
        PhyEvent event0 = getEmptyPhyEvent();
        event0.srcPhyId = 0;
        PhyEvent event1 = getEmptyPhyEvent();
        event1.srcPhyId = 1;
        nodes[0].phyTxSrv.request.put(event0);
        nodes[1].phyTxSrv.request.put(event1);
    endrule

    rule send3 if (cycleCount == fromInteger(30*valueOf(NODE_NUM)));
        $display("\nNode 3 sends two packets and Node 4 sends one packet at the same time");
        PhyEvent event0 = getEmptyPhyEvent();
        event0.srcPhyId = 3;
        event0.rfParam.power = 40*32;
        PhyEvent event1 = getEmptyPhyEvent();
        event1.srcPhyId = 4;
        event1.rfParam.power = 30*32;
        nodes[3].phyTxSrv.request.put(event0);
        nodes[4].phyTxSrv.request.put(event1);
    endrule

    // rule send4 if (cycleCount == 301);
    //     PhyEvent event0 = getEmptyPhyEvent();
    //     event0.srcPhyId = 3;
    //     nodes[3].phyTxSrv.request.put(event0);
    // endrule


    rule send5 if (cycleCount == fromInteger(50*valueOf(NODE_NUM)));
        $display("\nAll Nodes send a packet at the same time");
        Vector#(NODE_NUM, PhyEvent) events = replicate(getEmptyPhyEvent());
        for(Integer j=0; j<valueof(NODE_NUM); j=j+1) begin
            events[j].srcPhyId = fromInteger(j);
            nodes[j].phyTxSrv.request.put(events[j]);
        end
    endrule

    rule simEnd if(cycleCount == fromInteger(1000*valueOf(NODE_NUM)));
        $display("\nTest end");
        $finish;
    endrule


    rule rx0;//Node0
        let received <- nodes[0].phyRxClt.request.get;
        $display("Node0 receive from Node%0d  power:%d",received.srcPhyId, received.rfParam.power);
    endrule

    rule rx1;//Node  7
        let received <- nodes[1].phyRxClt.request.get;
        $display("Node1 receive from Node%0d  power:%d",received.srcPhyId, received.rfParam.power);
    endrule

    for (Integer i = 2; i < valueof(NODE_NUM); i = i + 1) begin
        rule receive;
            let rxReq <- nodes[i].phyRxClt.request.get;
        endrule
    end
endmodule



//----------------------------------------------
// 8 - 2
//----------------------------------------------

// import GetPut::*;
// import Connectable::*;
// import ClientServer::*;
// import Vector::*;
// import FIFO::*;
// import MathUtils::*;


// import Types::*;
// import Poll::*;
// import Channel::*;

// typedef 3 TreeDepth;

// module mkTestPoll(Empty);
//     //实例化仲裁器
//     PollIFC poll <- mkPoll;
    
//     //创建节点模型
//     Vector#(NODE_NUM, GainLossModel) nodes <- genWithM(compose(mkGainLossModelIdeal, fromInteger));
    
//     //连接接口
//     for(Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
//         mkConnection(nodes[i].phyTxMetaClt, poll.phyRxMetaSrv[i]);
//         mkConnection(poll.phyTxMetaClt[i], nodes[i].phyRxMetaSrv);
//     end

//     Reg#(UInt#(64)) cycleCount <- mkReg(0);

//     rule updateclock;
//         cycleCount <= cycleCount + 1;
//     endrule

//     // 测试案例1：基础仲裁
//     rule send1 if (cycleCount == 100);
//         $display("\nNode2 sends a packet");
//         PhyEvent event2 = getEmptyPhyEvent();
//         event2.srcPhyId = 2;
//         nodes[2].phyTxSrv.request.put(event2);
//     endrule

//     rule send2 if (cycleCount == 200);
//         $display("\nNode0 and Node1 send a packet at the same time");
//         PhyEvent event0 = getEmptyPhyEvent();
//         event0.srcPhyId = 0;
//         PhyEvent event1 = getEmptyPhyEvent();
//         event1.srcPhyId = 1;
//         nodes[0].phyTxSrv.request.put(event0);
//         nodes[1].phyTxSrv.request.put(event1);
//     endrule

//     rule send3 if (cycleCount == 300);
//         $display("\nNode 3 sends two packets and Node 4 sends one packet at the same time");
//         PhyEvent event0 = getEmptyPhyEvent();
//         event0.srcPhyId = 3;
//         PhyEvent event1 = getEmptyPhyEvent();
//         event1.srcPhyId = 4;
//         nodes[3].phyTxSrv.request.put(event0);
//         nodes[4].phyTxSrv.request.put(event1);
//     endrule

//     rule send4 if (cycleCount == 301);
//         PhyEvent event0 = getEmptyPhyEvent();
//         event0.srcPhyId = 3;
//         nodes[3].phyTxSrv.request.put(event0);
//     endrule

//     rule send5 if (cycleCount == 500);
//         $display("\nAll Nodes send a packet at the same time");
//         Vector#(NODE_NUM, PhyEvent) events = replicate(getEmptyPhyEvent());
//         for(Integer j=0; j<valueOf(NODE_NUM); j=j+1) begin
//             events[j].srcPhyId = fromInteger(j);
//             nodes[j].phyTxSrv.request.put(events[j]);
//         end
//     endrule

//     rule simEnd if(cycleCount == 1000);
//         $display("\nTest end");
//         $finish;
//     endrule


//     rule rx6;//Node0
//         let received <- nodes[0].phyRxClt.request.get;
//         $display("Node0 receive from Node%0d",received.srcPhyId);
//     endrule

//     rule rx7;//Node  7
//         let received <- nodes[7].phyRxClt.request.get;
//         $display("Node7 receive from Node%0d",received.srcPhyId);
//     endrule
// endmodule