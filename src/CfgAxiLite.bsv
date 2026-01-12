import GetPut::*;
import Connectable::*;
import ClientServer::*;
import Vector::*;
import FIFOF::*;
import FIFO::*;
import RegFile::*;

import Types::*;
import Axi4LiteTypes::*;


// ================================================================
// 节点控制管理器接口
// ================================================================
interface NodeControlManager_IFC;
    interface DmaAxiLiteSlave axiLiteSlave;
    interface Vector#(NODE_NUM, RegAccessClt) macRegClients;
    interface Vector#(NODE_NUM, RegAccessClt) phyRegClients;
endinterface

// ================================================================
// AXI-Lite节点控制管理器模块
// ================================================================
module mkAxiLiteNodeControlManager(NodeControlManager_IFC);
    // ================================================================
    // 内部状态
    // ================================================================
    // AXI-Lite接口
    Axi4LiteSlave#(AXI_ADDR_WIDTH, AXI_DATA_WIDTH) axiLiteSlave_ifc <- mkAxi4LiteSlave;
    
    // 请求和响应队列
    FIFOF#(RegAccessReq)  regReqQ  <- mkFIFOF;
    FIFOF#(RegAccessResp) regRespQ <- mkFIFOF;
    
    // 节点组子管理器
    Vector#(NODE_GROUP_LITE, NodeControlSubManager_IFC) subManagers <- replicateM(mkAxiLiteNodeControlSubManager);
    
    // 组请求和响应队列
    Vector#(NODE_GROUP_LITE, FIFOF#(RegAccessReq))  groupReqQs  <- replicateM(mkFIFOF);
    Vector#(NODE_GROUP_LITE, FIFOF#(RegAccessResp)) groupRespQs <- replicateM(mkFIFOF);
    
    // ================================================================
    // AXI-Lite到RegAccess转换
    // ================================================================
    // 处理写请求
    rule processWriteRequest;
        let writeReq <- axiLiteSlave_ifc.aw.get;
        let writeData <- axiLiteSlave_ifc.w.get;
        
        // 地址解码
        Bit#(32) addr = writeReq.awaddr;
        Bool isValidAddr = (addr >= node_base_addr) && (addr < node_addr_max);
        
        if (isValidAddr) begin
            // 转换为RegAccessReq
            RegAccessReq req = RegAccessReq{
                writeEnable: True,
                regOffset: truncate(addr - node_base_addr),
                writeData: writeData.wdata
            };
            regReqQ.enq(req);
        end else begin
            // 直接返回错误响应
            let b_resp = Axi4LiteBFlit{
                bresp: AXI4_LITE_SLVERR,
                buser: 0
            };
            axiLiteSlave_ifc.b.put(b_resp);
        end
    endrule
    
    // 处理读请求
    rule processReadRequest;
        let readReq <- axiLiteSlave_ifc.ar.get;
        
        // 地址解码
        Bit#(32) addr = readReq.araddr;
        Bool isValidAddr = (addr >= node_base_addr) && (addr < node_addr_max);
        
        if (isValidAddr) begin
            // 转换为RegAccessReq
            RegAccessReq req = RegAccessReq{
                writeEnable: False,
                regOffset: truncate(addr - node_base_addr),
                writeData: 0
            };
            regReqQ.enq(req);
        end else begin
            // 返回错误响应
            let r_resp = Axi4LiteRFlit{
                rresp: AXI4_LITE_SLVERR,
                rdata: 0,
                ruser: 0
            };
            axiLiteSlave_ifc.r.put(r_resp);
        end
    endrule
    
    // ================================================================
    // 寄存器访问处理逻辑
    // ================================================================
    // 地址解码和请求转发
    rule decodeAndForwardRequest;
        let req = regReqQ.first;
        regReqQ.deq;
        
        // 解码组索引
        Bit#(32) nodeOffset = req.regOffset;
        Bit#(8) groupIdx = truncate(nodeOffset >> 10); // 每个节点1KB，每个组包含2个节点 = 2KB per group
        Bit#(32) groupOffset = truncate(nodeOffset);
        
        if (groupIdx >= fromInteger(valueOf(NODE_GROUP_LITE))) begin
            // 无效组索引
            RegAccessResp resp = RegAccessResp{readData: 0, error: True};
            regRespQ.enq(resp);
        end else begin
            // 转发到对应的组
            groupReqQs[groupIdx].enq(RegAccessReq{
                writeEnable: req.writeEnable,
                regOffset: groupOffset,
                writeData: req.writeData
            });
        end
    endrule
    
    // 响应处理
    rule processResponse;
        RegAccessResp resp = RegAccessResp{readData: 0, error: True};
        Bool hasResponse = False;
        
        // 检查所有组的响应队列
        for (Integer i = 0; i < valueOf(NODE_GROUP_LITE); i = i + 1) begin
            if (groupRespQs[i].notEmpty) begin
                resp = groupRespQs[i].first;
                groupRespQs[i].deq;
                hasResponse = True;
                break;
            end
        end
        
        if (hasResponse) begin
            regRespQ.enq(resp);
        end
    endrule
    
    // 返回AXI-Lite响应
    rule returnWriteResponse;
        let resp = regRespQ.first;
        regRespQ.deq;
        
        let b_resp = Axi4LiteBFlit{
            bresp: resp.error ? AXI4_LITE_SLVERR : AXI4_LITE_OKAY,
            buser: 0
        };
        axiLiteSlave_ifc.b.put(b_resp);
    endrule
    
    rule returnReadResponse;
        let resp = regRespQ.first;
        regRespQ.deq;
        
        let r_resp = Axi4LiteRFlit{
            rresp: resp.error ? AXI4_LITE_SLVERR : AXI4_LITE_OKAY,
            rdata: resp.readData,
            ruser: 0
        };
        axiLiteSlave_ifc.r.put(r_resp);
    endrule
    
    // ================================================================
    // 子管理器连接
    // ================================================================
    // 连接子管理器的寄存器访问接口
    for (Integer i = 0; i < valueOf(NODE_GROUP_LITE); i = i + 1) begin
        mkConnection(
            toGet(groupReqQs[i]),
            subManagers[i].regAccessSrv.request
        );
        
        mkConnection(
            subManagers[i].regAccessSrv.response,
            toPut(groupRespQs[i])
        );
    end
    
    // ================================================================
    // 接口实现
    // ================================================================
    interface DmaAxiLiteSlave axiLiteSlave = toDmaAxiLiteSlave(axiLiteSlave_ifc);
    
    // 生成MAC和PHY寄存器客户端接口
    interface Vector#(NODE_NUM, RegAccessClt) macRegClients =
        genWith(
            function RegAccessClt genMacClient(Integer i);
                Integer groupIdx = i / valueOf(NODE_PER_GROUP_LITE);
                Integer nodeIdx = i % valueOf(NODE_PER_GROUP_LITE);
                return subManagers[groupIdx].macRegClients[nodeIdx];
            endfunction
        );
    
    interface Vector#(NODE_NUM, RegAccessClt) phyRegClients =
        genWith(
            function RegAccessClt genPhyClient(Integer i);
                Integer groupIdx = i / valueOf(NODE_PER_GROUP_LITE);
                Integer nodeIdx = i % valueOf(NODE_PER_GROUP_LITE);
                return subManagers[groupIdx].phyRegClients[nodeIdx];
            endfunction
        );
    endinterface

interface NodeControlSubManager_IFC;
    interface RegAccessSrv regAccessSrv;
    interface Vector#(NODE_PER_GROUP_LITE, RegAccessClt) macRegClients;
    interface Vector#(NODE_PER_GROUP_LITE, RegAccessClt) phyRegClients;
endinterface

module mkAxiLiteNodeControlSubManager(NodeControlSubManager_IFC);
    // ================================================================
    // 内部状态
    // ================================================================
    // 请求和响应队列
    FIFOF#(RegAccessReq)  regReqQ  <- mkFIFOF;
    FIFOF#(RegAccessResp) regRespQ <- mkFIFOF;
    
    // MAC和PHY寄存器客户端
    Vector#(NODE_PER_GROUP_LITE, FIFOF#(RegAccessReq))  macReqQs  <- replicateM(mkFIFOF);
    Vector#(NODE_PER_GROUP_LITE, FIFOF#(RegAccessResp)) macRespQs <- replicateM(mkFIFOF);
    
    Vector#(NODE_PER_GROUP_LITE, FIFOF#(RegAccessReq))  phyReqQs  <- replicateM(mkFIFOF);
    Vector#(NODE_PER_GROUP_LITE, FIFOF#(RegAccessResp)) phyRespQs <- replicateM(mkFIFOF);
    
    // ================================================================
    // 寄存器访问处理逻辑
    // ================================================================
    rule processRegRequest;
        let req = regReqQ.first;
        regReqQ.deq;
        
        // 解码节点索引和寄存器类型
        // 每个节点有1KB空间，其中前512B是MAC寄存器，后512B是PHY寄存器
        Bit#(32) nodeOffset = req.regOffset;
        Bit#(8) nodeIdx = truncate(nodeOffset >> 10); // 1KB per node
        Bit#(32) regAddr = truncate(nodeOffset);
        
        if (nodeIdx >= fromInteger(valueOf(NODE_PER_GROUP_LITE))) begin
            // 无效节点索引
            RegAccessResp resp = RegAccessResp{readData: 0, error: True};
            regRespQ.enq(resp);
        end else if (regAddr < node_mac_size) begin
            // MAC寄存器访问
            macReqQs[nodeIdx].enq(RegAccessReq{
                writeEnable: req.writeEnable,
                regOffset: regAddr,
                writeData: req.writeData
            });
        end else if (regAddr < node_per_node) begin
            // PHY寄存器访问
            Bit#(32) phyRegAddr = regAddr - node_phy_offset;
            phyReqQs[nodeIdx].enq(RegAccessReq{
                writeEnable: req.writeEnable,
                regOffset: phyRegAddr,
                writeData: req.writeData
            });
        end else begin
            // 无效寄存器地址
            RegAccessResp resp = RegAccessResp{readData: 0, error: True};
            regRespQ.enq(resp);
        end
    endrule
    
    // 处理MAC响应
    for (Integer i = 0; i < valueOf(NODE_PER_GROUP_LITE); i = i + 1) begin
        rule processMacResponse;
            let resp = macRespQs[i].first;
            macRespQs[i].deq;
            regRespQ.enq(resp);
        endrule
    end
    
    // 处理PHY响应
    for (Integer i = 0; i < valueOf(NODE_PER_GROUP_LITE); i = i + 1) begin
        rule processPhyResponse;
            let resp = phyRespQs[i].first;
            phyRespQs[i].deq;
            regRespQ.enq(resp);
        endrule
    end
    
    // ================================================================
    // 接口实现
    // ================================================================
    interface RegAccessSrv regAccessSrv;
        interface Put request = toPut(regReqQ);
        interface Get response = toGet(regRespQ);
    endinterface
    
    interface Vector#(NODE_PER_GROUP_LITE, RegAccessClt) macRegClients;
        genList(function RegAccessClt genMacClient(Integer i);
            return (interface RegAccessClt;
                interface Get request = toGet(macReqQs[i]);
                interface Put response = toPut(macRespQs[i]);
            endinterface);
        endfunction);
    endinterface
    
    interface Vector#(NODE_PER_GROUP_LITE, RegAccessClt) phyRegClients;
        genList(function RegAccessClt genPhyClient(Integer i);
            return (interface RegAccessClt;
                interface Get request = toGet(phyReqQs[i]);
                interface Put response = toPut(phyRespQs[i]);
            endinterface);
        endfunction);
    endinterface
endmodule

