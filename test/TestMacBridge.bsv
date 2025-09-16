import GetPut::*;
import Connectable::*;
import ClientServer::*;
import Vector::*;
import FIFO::*;
import MathUtils::*;
import BRAM::*;


import Types::*;
import MacBridge::*;
// import Arbitration::*;
// import Channel::*;

function Action printMacEvent(MacEvent macEvent);
    action
        $display("MacEvent {");
        $display("  srcMacId: %0d", macEvent.srcMacId);
        $display("  dstMacId: %0d", macEvent.dstMacId);
        $display("  rfParam: {");
        $display("    power: %0d", macEvent.rfParam.power);
        $display("    mcs: %0d", macEvent.rfParam.mcs);
        $display("  }");
        $display("  mpduDigest: {");
        $display("    frameType: %0b", macEvent.mpduDigest.frameType);
        $display("    frameSubType: %0b", macEvent.mpduDigest.frameSubType);
        $display("    duration: %0d", macEvent.mpduDigest.duration);
        $display("    length: %0d", macEvent.mpduDigest.length);
        $display("    cacheAddr: %0h", macEvent.mpduDigest.cacheAddr);
        $display("  }");
        $display("  status: %0b", macEvent.status);
        $display("}");
    endaction
endfunction

module mkTestMacBridge(Empty);

    Reg#(UInt#(64)) cycleCount <- mkReg(0);

    let macBridge <- mkMacBridge;

    rule pkt_send_pcie (cycleCount%1000 == 0);
        let pkt = getEmptyMacEvent;
        pkt.srcMacId = 3;
        pkt.dstMacId = 1;
        macBridge.pcieTxSrv.request.put(pkt);
        $display("pkt_send_pcie: %x", pkt);
    endrule

    rule pkt_send_mac;
        let pkt <- macBridge.macTxClt[3].request.get;
        $display("pkt_send_mac: %x", pkt);
    endrule
    
    
    // rule pkt_Recv_mac;
    //     let pkt = getEmptyMacEvent;
    //     pkt.srcMacId = 3;
    //     pkt.dstMacId = 1;
    //     macBridge.macRxSrv[1].request.put(pkt);
    //     $display("pkt_Recv_mac: %x", pkt);
    //     printMacEvent(pkt); 
    // endrule

    // rule pkt_Recv_pcie (cycleCount%1000 == 0);
    //     let pkt <- macBridge.pcieRxClt.request.get;
    //     $display("pkt_Recv_pcie: %x", pkt);
    // endrule

    rule txhandshake_pcie;
        let rsp <- macBridge.pcieTxSrv.response.get;
    endrule

    rule rxhandshake_mac;
        let rsp <- macBridge.macRxSrv[1].response.get;
    endrule

    rule updateclock;
        cycleCount <= cycleCount + 1;
    endrule

    rule finish(cycleCount > 10000);
        $finish;
    endrule

endmodule