import GetPut::*;
import StmtFSM::*;
import FIFOF::*;
import Types::*;
import BsvTov_simple::*;
import AxiStreamTypes::*;
import Axi4LiteTypes::*;

function MacId targetNode(UInt#(3) index);
    case (index)
        0: return 0; 1: return 3; 2: return 4; default: return 15;
    endcase
endfunction

// Full 16-node core: AXI-Lite group boundaries, committed stream config, then DATA.
module mkTestConfigFence(Empty);
    let core <- mkEmuCore;
    Reg#(UInt#(32)) cycle <- mkReg(0);
    Reg#(UInt#(3)) nodeIndex <- mkReg(0);
    Reg#(UInt#(6)) perIndex <- mkReg(0);
    FIFOF#(Bit#(32)) aw <- mkFIFOF;
    FIFOF#(Bit#(32)) wd <- mkFIFOF;
    FIFOF#(Bit#(2)) br <- mkFIFOF;
    FIFOF#(Bit#(32)) ar <- mkFIFOF;
    FIFOF#(Tuple2#(Bit#(2), Bit#(32))) rr <- mkFIFOF;
    rule tick; cycle <= cycle + 1; endrule
    rule writeAddress;
        core.dmaAxiLiteSlave.wrSlave.awValidData(aw.notEmpty, aw.notEmpty ? aw.first : 0, 0);
        if (aw.notEmpty && core.dmaAxiLiteSlave.wrSlave.awReady) aw.deq;
    endrule
    rule writeData;
        core.dmaAxiLiteSlave.wrSlave.wValidData(wd.notEmpty, wd.notEmpty ? wd.first : 0, '1);
        if (wd.notEmpty && core.dmaAxiLiteSlave.wrSlave.wReady) wd.deq;
    endrule
    rule writeResponse;
        core.dmaAxiLiteSlave.wrSlave.bReady(br.notFull);
        if (br.notFull && core.dmaAxiLiteSlave.wrSlave.bValid) br.enq(core.dmaAxiLiteSlave.wrSlave.bResp);
    endrule
    rule readAddress;
        core.dmaAxiLiteSlave.rdSlave.arValidData(ar.notEmpty, ar.notEmpty ? ar.first : 0, 0);
        if (ar.notEmpty && core.dmaAxiLiteSlave.rdSlave.arReady) ar.deq;
    endrule
    rule readResponse;
        core.dmaAxiLiteSlave.rdSlave.rReady(rr.notFull);
        if (rr.notFull && core.dmaAxiLiteSlave.rdSlave.rValid)
            rr.enq(tuple2(core.dmaAxiLiteSlave.rdSlave.rResp, core.dmaAxiLiteSlave.rdSlave.rData));
    endrule
    function Stmt writeCfg(MacId node, RegOffset offset, Bit#(32) value);
        return seq
            aw.enq(node_base_addr + zeroExtend(pack(node)) * node_per_node + offset);
            delay(2); // AW and W deliberately arrive separately.
            wd.enq(value);
            action
                let response = br.first; br.deq;
                if (response != 0) begin $display("TEST_FAIL AXI config write"); $finish(1); end
            endaction
        endseq;
    endfunction
    function Stmt readCfg(MacId node, RegOffset offset, Bit#(32) expected);
        return seq
            ar.enq(node_base_addr + zeroExtend(pack(node)) * node_per_node + offset);
            action
                let {response, value} = rr.first; rr.deq;
                if (response != 0 || value != expected) begin
                    $display("TEST_FAIL AXI readback node=%0d got=%0d expected=%0d", node, value, expected); $finish(1);
                end
            endaction
        endseq;
    endfunction
    function Action putDistance(MacId src, MacId dst);
        return action
            CfgBridge_TOP packet = CfgBridge_TOP{channelCfg: ChannelCfg{srcPhyId: src, dstPhyId: dst, distance: 16},
                bridgeTag: BridgeTag{control: 1, notUsed: 0}};
            core.tx.put(AxiStream{tData: zeroExtend(pack(packet)), tKeep: '1, tLast: True, tUser: 0});
        endaction;
    endfunction
    function Action putPer(UInt#(6) index);
        return action
            // 20lgd.mem[16] = 771: RX power = 1000 - 771 = 229.
            // Cover the header/noise sample and MCS7 whole-packet lookup.
            PerIn address = index % 3 == 0 ? 381 : (index % 3 == 1 ? 389 : 8229);
            CfgBridge_TOP_Per packet = CfgBridge_TOP_Per{perCfg: PerCfg{perIn: address, perOut: 65535},
                bridgeTag: BridgeTag{control: 1, notUsed: 1}};
            core.tx.put(AxiStream{tData: zeroExtend(pack(packet)), tKeep: '1, tLast: True, tUser: 0});
        endaction;
    endfunction
    function Action putData(MacId dst);
        return action
            let packet = getEmptyMacEvent;
            packet.srcMacId = 1; packet.dstMacId = dst;
            packet.rfParam = RfParam{power: 1000, mcs: 7};
            packet.mpduDigest.frameType = fromInteger(valueOf(FC_TYPE_DATA));
            packet.mpduDigest.length = 1062;
            packet.mpduDigest.cacheAddr = zeroExtend(pack(dst));
            core.tx.put(AxiStream{tData: zeroExtend(pack(tuple2(packet, getEmptyBridgeTag))), tKeep: '1, tLast: True, tUser: 0});
            $display("TRACE DATA_SUBMITTED cycle=%0d dst=%0d", cycle, dst);
        endaction;
    endfunction
    Stmt test = seq
        writeCfg(1, mac_cw_min_off, 0);
        writeCfg(1, mac_cw_max_off, 0);
        writeCfg(1, mac_difs_off, 3);
        for (nodeIndex <= 0; nodeIndex < 4; nodeIndex <= nodeIndex + 1) seq
            writeCfg(targetNode(nodeIndex), mac_sifs_off, zeroExtend(pack(targetNode(nodeIndex))) + 4);
            readCfg(targetNode(nodeIndex), mac_sifs_off, zeroExtend(pack(targetNode(nodeIndex))) + 4);
            putDistance(1, targetNode(nodeIndex));
            putDistance(targetNode(nodeIndex), 1);
        endseq
        for (perIndex <= 0; perIndex < 32; perIndex <= perIndex + 1) putPer(perIndex);
        for (nodeIndex <= 0; nodeIndex < 4; nodeIndex <= nodeIndex + 1) seq
            putData(targetNode(nodeIndex)); // No sleep/fence supplied by the test before this DATA.
            action
                let raw <- core.rx.get;
                MacEvent packet = unpack(truncate(raw.tData));
                if (packet.srcMacId != 1 || packet.dstMacId != targetNode(nodeIndex)
                    || packet.mpduDigest.cacheAddr != zeroExtend(pack(targetNode(nodeIndex)))
                    || packet.rfParam.power != 229) begin
                    $display("TEST_FAIL configured DATA wrong ID/destination"); $finish(1);
                end
                $display("CONFIG_NODE_PASS node=%0d", targetNode(nodeIndex));
            endaction
            delay(fromInteger(100 * valueOf(US_CYCLES)));
        endseq
        action $display("TEST_PASS config_fence full_16node_core"); $finish(0); endaction
    endseq;
    mkAutoFSM(test);
    rule watchdog(cycle == fromInteger(10000 * valueOf(US_CYCLES)));
        $display("TEST_FAIL config fence watchdog"); $finish(1);
    endrule
endmodule
