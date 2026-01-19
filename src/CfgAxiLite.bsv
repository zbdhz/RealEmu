import GetPut::*;
import Connectable::*;
import ClientServer::*;
import Vector::*;
import FIFOF::*;
import FIFO::*;
import RegFile::*;

import Types::*;
import Axi4LiteTypes::*;
import SemiFifo::*;



// ================================================================
// 节点控制管理器接口
// ================================================================
interface NodeControlManager_IFC;
    interface DmaAxiLiteSlave axiLiteSlave;
    interface Vector#(NODE_NUM, RegAccessClt) macRegClients;
    interface Vector#(NODE_NUM, RegAccessClt) phyRegClients;
endinterface

// ================================================================
// AXI-Lite请求处理状态机枚举
// ================================================================
typedef enum {
    IDLE,
    PROCESSING_WR,
    PROCESSING_RD,
    WAITING_WR_RESP,
    WAITING_RD_RESP
} AxiLiteState deriving(Bits, Eq, FShow);

// ================================================================
// AXI-Lite节点控制管理器模块
// ================================================================
(* synthesize *)
module mkAxiLiteNodeControlManager(NodeControlManager_IFC);
    // ================================================================
    // 内部状态
    // ================================================================
    // AXI-Lite FIFO队列
    FIFOF#(Axi4LiteWrAddr#(AXI_ADDR_WIDTH)) wrAddrQ <- mkFIFOF;
    FIFOF#(Axi4LiteWrData#(TDiv#(AXI_DATA_WIDTH, BYTE_WIDTH))) wrDataQ <- mkFIFOF;
    FIFOF#(Axi4LiteWrResp) wrRespQ <- mkFIFOF;
    FIFOF#(Axi4LiteRdAddr#(AXI_ADDR_WIDTH)) rdAddrQ <- mkFIFOF;
    FIFOF#(Axi4LiteRdData#(TDiv#(AXI_DATA_WIDTH, BYTE_WIDTH))) rdDataQ <- mkFIFOF;
    
    // 使用正确的RawAxi4LiteSlave接口
    DmaAxiLiteSlave axiLiteSlave_ifc <- mkRawAxi4LiteSlave(
        convertFifoToFifoIn(wrAddrQ),
        convertFifoToFifoIn(wrDataQ),
        convertFifoToFifoOut(wrRespQ),
        convertFifoToFifoIn(rdAddrQ),
        convertFifoToFifoOut(rdDataQ)
    );
    
    // 请求和响应队列已删除，寄存器访问逻辑已整合到状态机中
    
    // 节点组子管理器
    Vector#(NODE_GROUP_LITE, NodeControlSubManager_IFC) subManagers <- replicateM(mkAxiLiteNodeControlSubManager);
    
    // 组请求和响应队列已替换为直接使用subManagers的regAccessSrv接口
    
    // 状态机状态
    Reg#(AxiLiteState) state <- mkReg(IDLE);
    
    // 存储当前请求的信息
    Reg#(Bool) isWriteReq <- mkReg(False);
    Reg#(Bool) isValidAddr <- mkReg(False);
    Reg#(Bit#(32)) currentAddr <- mkReg(0);
    Reg#(Bit#(8)) currentGroupIdx <- mkReg(0);
    
    // ================================================================
    // AXI-Lite到RegAccess转换（使用状态机）
    // ================================================================
    // 状态机规则1：IDLE状态，处理请求地址（写优先）
    rule processAddr(state == IDLE);
        if (wrAddrQ.notEmpty) begin
            // 处理写请求地址
            let writeReq = wrAddrQ.first;
            wrAddrQ.deq;
            
            // 地址解码
            Bit#(32) addr = writeReq.awAddr;
            Bool validAddr = (addr >= node_base_addr) && (addr < node_addr_max);
            
            // 存储请求信息
            isWriteReq <= True;
            isValidAddr <= validAddr;
            currentAddr <= addr;
            
            // 进入处理写数据状态
            state <= PROCESSING_WR;
            // 打印对应的待处理的全部信息
            $display("[CfgAxiLite]   Processing write request:");
            $display("[CfgAxiLite]   Address: 0x%h", addr);
            $display("[CfgAxiLite]   Valid: %b", validAddr);
            $display("[CfgAxiLite]   State transition: IDLE -> PROCESSING_WR");
        end else if (rdAddrQ.notEmpty) begin
            // 处理读请求地址
            let readReq = rdAddrQ.first;
            rdAddrQ.deq;
            
            // 地址解码
            Bit#(32) addr = readReq.arAddr;
            Bool validAddr = (addr >= node_base_addr) && (addr < node_addr_max);
            
            // 存储请求信息
            isWriteReq <= False;
            isValidAddr <= validAddr;
            currentAddr <= addr;
            
            // 进入处理读数据状态
            state <= PROCESSING_RD;
            // 打印读请求信息
            $display("[CfgAxiLite]   Processing read request:");
            $display("[CfgAxiLite]   Address: 0x%h", addr);
            $display("[CfgAxiLite]   Valid: %b", validAddr);
            $display("[CfgAxiLite]   State transition: IDLE -> PROCESSING_RD");
        end
    endrule
    
    // 状态机规则2：PROCESSING_WR状态，处理写数据
    rule processWriteData(state == PROCESSING_WR && wrDataQ.notEmpty);
        let writeData = wrDataQ.first;
        wrDataQ.deq;
        
        if (isValidAddr) begin
            // 直接进行地址解码和请求转发
            Bit#(32) nodeOffset = truncate(currentAddr - node_base_addr);
            // 计算组号：每个节点占用NODE_ADDR_SIZE，每个组包含NODE_PER_GROUP_LITE个节点
            // 使用NODE_ADDR_BITS和TLog#计算总偏移位数
            Bit#(8) groupIdx = truncate(nodeOffset >> (fromInteger(valueOf(NODE_ADDR_BITS)) + fromInteger(valueOf(TLog#(NODE_PER_GROUP_LITE)))));
            // 计算组内偏移：使用掩码替代取模
            Bit#(32) groupMask = ((1 << (fromInteger(valueOf(NODE_ADDR_BITS)) + fromInteger(valueOf(TLog#(NODE_PER_GROUP_LITE))))) - 1);
            Bit#(32) groupOffset = truncate(nodeOffset & groupMask);
            
            // 打印地址解码信息
            $display("[CfgAxiLite]   Address decoding:");
            $display("[CfgAxiLite]   Current Address: 0x%h", currentAddr);
            $display("[CfgAxiLite]   Node Base Address: 0x%h", node_base_addr);
            $display("[CfgAxiLite]   Node Offset: 0x%h", nodeOffset);
            $display("[CfgAxiLite]   Group Index: %d", groupIdx);
            $display("[CfgAxiLite]   Group Offset: 0x%h", groupOffset);
            
            if (groupIdx >= fromInteger(valueOf(NODE_GROUP_LITE))) begin
                // 无效组索引，直接返回错误
                RegAccessResp resp = RegAccessResp{readData: 0, error: True};
                wrRespQ.enq(axi4_lite_slverr);
                state <= IDLE;
                $display("[CfgAxiLite] Invalid group index: %d, max group: %d", 
                         groupIdx, fromInteger(valueOf(NODE_GROUP_LITE)));
                $display("[CfgAxiLite] Returning SLVERR response");
                $display("[CfgAxiLite] State transition: PROCESSING_WR -> IDLE");
            end else begin
                // 存储当前组索引
                currentGroupIdx <= groupIdx;
                
                // 直接转发到对应的组管理器
                subManagers[groupIdx].regAccessSrv.request.put(RegAccessReq{
                    writeEnable: True,
                    regOffset: groupOffset,
                    writeData: writeData.wData
                });
                
                // 进入等待写响应状态
                state <= WAITING_WR_RESP;
            end
        end else begin
            // 直接返回错误响应
            wrRespQ.enq(axi4_lite_slverr);
            
            // 返回IDLE状态
            state <= IDLE;
        end
    endrule
    
    // 状态机规则3：PROCESSING_RD状态，处理读请求
    rule processReadRequest(state == PROCESSING_RD);
        if (isValidAddr) begin
            // 直接进行地址解码和请求转发
            Bit#(32) nodeOffset = truncate(currentAddr - node_base_addr);
            // 计算组号：每个节点占用NODE_ADDR_SIZE，每个组包含NODE_PER_GROUP_LITE个节点
            // 使用NODE_ADDR_BITS和TLog#计算总偏移位数
            Bit#(8) groupIdx = truncate(nodeOffset >> (fromInteger(valueOf(NODE_ADDR_BITS)) + fromInteger(valueOf(TLog#(NODE_PER_GROUP_LITE)))));
            // 计算组内偏移：使用掩码替代取模
            Bit#(32) groupMask = ((1 << (fromInteger(valueOf(NODE_ADDR_BITS)) + fromInteger(valueOf(TLog#(NODE_PER_GROUP_LITE))))) - 1);
            Bit#(32) groupOffset = truncate(nodeOffset & groupMask);
            
            if (groupIdx >= fromInteger(valueOf(NODE_GROUP_LITE))) begin
                // 无效组索引，直接返回错误
                $display("[CfgAxiLite] Invalid group index: %d, max group: %d", 
                         groupIdx, fromInteger(valueOf(NODE_GROUP_LITE)) - 1);
                $display("[CfgAxiLite] Returning SLVERR response");
                RegAccessResp resp = RegAccessResp{readData: 0, error: True};
                rdDataQ.enq(Axi4LiteRdData{
                    rResp: axi4_lite_slverr,
                    rData: 0
                });
                state <= IDLE;
                $display("[CfgAxiLite] State transition: PROCESSING_RD -> IDLE");
            end else begin
                // 存储当前组索引
                currentGroupIdx <= groupIdx;
                
                // 直接转发到对应的组管理器
                subManagers[groupIdx].regAccessSrv.request.put(RegAccessReq{
                    writeEnable: False,
                    regOffset: groupOffset,
                    writeData: 0
                });
                
                // 进入等待读响应状态
                state <= WAITING_RD_RESP;
                $display("[CfgAxiLite] State transition: PROCESSING_RD -> WAITING_RD_RESP");
                $display("[CfgAxiLite] Waiting for read response from group %d...", groupIdx);
            end
        end else begin
            // 直接返回错误响应
            rdDataQ.enq(Axi4LiteRdData{
                rResp: axi4_lite_slverr,
                rData: 0
            });
            
            // 返回IDLE状态
            state <= IDLE;
        end
    endrule
    
    // ================================================================
    // 状态机规则4：WAITING_WR_RESP状态，处理写响应
    // ================================================================
    // 处理写响应
    rule processWriteResponse(state == WAITING_WR_RESP);
        // 直接从组管理器获取响应
        let resp <- subManagers[currentGroupIdx].regAccessSrv.response.get;
        
        // 打印写响应信息
        $display("[CfgAxiLite] Processing write response from group %d:", currentGroupIdx);
        $display("[CfgAxiLite]   Read Data: 0x%h", resp.readData);
        $display("[CfgAxiLite]   Error: %b", resp.error);
        
        // 返回响应
        Bit#(AXI4_RESP_WIDTH) responseCode = resp.error ? axi4_lite_slverr : axi4_lite_okay;
        wrRespQ.enq(responseCode);
        $display("[CfgAxiLite] Returning write response: 0x%h", responseCode);
        
        // 返回IDLE状态
        state <= IDLE;
        $display("[CfgAxiLite] State transition: WAITING_WR_RESP -> IDLE");
    endrule
    
    // 状态机规则5：WAITING_RD_RESP状态，处理读响应
    // ================================================================
    // 处理读响应
    rule processReadResponse(state == WAITING_RD_RESP);
        // 直接从组管理器获取响应
        let resp <- subManagers[currentGroupIdx].regAccessSrv.response.get;
        
        // 打印读响应信息
        $display("[CfgAxiLite] Processing read response from group %d:", currentGroupIdx);
        $display("[CfgAxiLite]   Read Data: 0x%h", resp.readData);
        $display("[CfgAxiLite]   Error: %b", resp.error);
        
        // 返回响应
        Bit#(AXI4_RESP_WIDTH) responseCode = resp.error ? axi4_lite_slverr : axi4_lite_okay;
        Axi4LiteRdData#(TDiv#(AXI_DATA_WIDTH, BYTE_WIDTH)) rdResp = Axi4LiteRdData{
            rResp: responseCode,
            rData: resp.readData
        };
        rdDataQ.enq(rdResp);
        
        $display("[CfgAxiLite] Returning read response:");
        $display("[CfgAxiLite]   Response Code: 0x%h", rdResp.rResp);
        $display("[CfgAxiLite]   Read Data: 0x%h", rdResp.rData);
        
        // 返回IDLE状态
        state <= IDLE;
        $display("[CfgAxiLite] State transition: WAITING_RD_RESP -> IDLE");
    endrule
    
    // 删除了重复的returnWriteResponse和returnReadResponse规则，因为它们的功能已经在状态机的processWriteResponse和processReadResponse规则中实现
    
    
    // ================================================================
    // 接口实现
    // ================================================================
    
    // 生成MAC和PHY寄存器客户端接口
    Vector#(NODE_NUM, RegAccessClt) macRegClients_vec;
    Vector#(NODE_NUM, RegAccessClt) phyRegClients_vec;
    
    for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
        Integer groupIdx = i / valueOf(NODE_PER_GROUP_LITE);
        Integer nodeIdx = i % valueOf(NODE_PER_GROUP_LITE);
        macRegClients_vec[i] = subManagers[groupIdx].macRegClients[nodeIdx];
        phyRegClients_vec[i] = subManagers[groupIdx].phyRegClients[nodeIdx];
    end
    
    interface macRegClients = macRegClients_vec;
    interface phyRegClients = phyRegClients_vec;
    // AXI-Lite接口
    interface axiLiteSlave = axiLiteSlave_ifc;

endmodule

interface NodeControlSubManager_IFC;
    interface RegAccessSrv regAccessSrv;
    interface Vector#(NODE_PER_GROUP_LITE, RegAccessClt) macRegClients;
    interface Vector#(NODE_PER_GROUP_LITE, RegAccessClt) phyRegClients;
endinterface

// 状态机定义
typedef enum {
    IDLE,          // 空闲状态
    WAIT_MAC_RESP, // 等待MAC响应
    WAIT_PHY_RESP  // 等待PHY响应
} State deriving(Eq, Bits, FShow);

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
    
    
    Reg#(State) state <- mkReg(IDLE);
    Reg#(Bit#(10)) currNodeIdx <- mkReg(0);
    
    // ================================================================
    // 寄存器访问处理逻辑
    // ================================================================
    // IDLE状态：处理新请求
    rule processReqIdle(state == IDLE && regReqQ.notEmpty);
        let req = regReqQ.first;
        regReqQ.deq;
        
        // 解码节点索引和寄存器类型
        Bit#(32) nodeOffset = req.regOffset;
        Bit#(10) nodeIdx = truncate(nodeOffset >> fromInteger(valueOf(NODE_ADDR_BITS))); // 使用NODE_ADDR_BITS替代固定10位偏移
        // 使用掩码替代取模操作，提高硬件效率
        Bit#(32) nodeMask = ((1 << fromInteger(valueOf(NODE_ADDR_BITS))) - 1);
        Bit#(32) regAddr = truncate(nodeOffset & nodeMask);
        
        // 添加调试信息
        $display("[NodeControlSubManager] State: IDLE, processing new request");
        $display("[NodeControlSubManager]   Request type: %s", req.writeEnable ? "WRITE" : "READ");
        $display("[NodeControlSubManager]   Register offset: 0x%h", req.regOffset);
        $display("[NodeControlSubManager]   Write data: 0x%h", req.writeData);
        $display("[NodeControlSubManager]   Decoded node index: %d", nodeIdx);
        $display("[NodeControlSubManager]   Decoded register address: 0x%h", regAddr);
        
        if (nodeIdx >= fromInteger(valueOf(NODE_PER_GROUP_LITE)) || regAddr >= node_per_node) begin
            // 无效节点索引或寄存器地址
            $display("[NodeControlSubManager]   Invalid request: node index %d or register address 0x%h out of range", nodeIdx, regAddr);
            RegAccessResp resp = RegAccessResp{readData: 0, error: True};
            regRespQ.enq(resp);
            $display("[NodeControlSubManager]   Returning error response");
            // 保持IDLE状态
        end else if (regAddr < node_mac_size) begin
            // MAC寄存器访问
            $display("[NodeControlSubManager]   Routing to MAC registers for node %d", nodeIdx);
            macReqQs[nodeIdx].enq(RegAccessReq{
                writeEnable: req.writeEnable,
                regOffset: regAddr,
                writeData: req.writeData
            });
            // 记录当前节点索引并进入等待MAC响应状态
            currNodeIdx <= nodeIdx;
            state <= WAIT_MAC_RESP;
            $display("[NodeControlSubManager] State transition: IDLE -> WAIT_MAC_RESP");
        end else begin
            // PHY寄存器访问
            $display("[NodeControlSubManager]   Routing to PHY registers for node %d", nodeIdx);
            phyReqQs[nodeIdx].enq(RegAccessReq{
                writeEnable: req.writeEnable,
                regOffset: regAddr,
                writeData: req.writeData
            });
            // 记录当前节点索引并进入等待PHY响应状态
            currNodeIdx <= nodeIdx;
            state <= WAIT_PHY_RESP;
            $display("[NodeControlSubManager] State transition: IDLE -> WAIT_PHY_RESP");
        end
    endrule
    
    // 等待MAC响应状态
    rule processMacResponse(state == WAIT_MAC_RESP && macRespQs[currNodeIdx].notEmpty);
        $display("[NodeControlSubManager] State: WAIT_MAC_RESP, processing MAC response for node %d", currNodeIdx);
        let resp = macRespQs[currNodeIdx].first;
        macRespQs[currNodeIdx].deq;
        
        $display("[NodeControlSubManager]   MAC response data: 0x%h", resp.readData);
        $display("[NodeControlSubManager]   MAC response error: %b", resp.error);
        
        regRespQ.enq(resp);
        // 返回IDLE状态处理下一个请求
        state <= IDLE;
        $display("[NodeControlSubManager] State transition: WAIT_MAC_RESP -> IDLE");
    endrule
    
    // 等待PHY响应状态
    rule processPhyResponse(state == WAIT_PHY_RESP && phyRespQs[currNodeIdx].notEmpty);
        $display("[NodeControlSubManager] State: WAIT_PHY_RESP, processing PHY response for node %d", currNodeIdx);
        let resp = phyRespQs[currNodeIdx].first;
        phyRespQs[currNodeIdx].deq;
        
        $display("[NodeControlSubManager]   PHY response data: 0x%h", resp.readData);
        $display("[NodeControlSubManager]   PHY response error: %b", resp.error);
        
        regRespQ.enq(resp);
        // 返回IDLE状态处理下一个请求
        state <= IDLE;
        $display("[NodeControlSubManager] State transition: WAIT_PHY_RESP -> IDLE");
    endrule
    
    // ================================================================
    // 接口实现
    // ================================================================

    // 生成MAC和PHY寄存器客户端
    Vector#(NODE_PER_GROUP_LITE, RegAccessClt) macRegClients_vec;
    Vector#(NODE_PER_GROUP_LITE, RegAccessClt) phyRegClients_vec;

    for (Integer i = 0; i < valueOf(NODE_PER_GROUP_LITE); i = i + 1) begin
        macRegClients_vec[i] = toGPClient(macReqQs[i], macRespQs[i]);
        phyRegClients_vec[i] = toGPClient(phyReqQs[i], phyRespQs[i]);
    end

    // 接口定义
    interface RegAccessSrv regAccessSrv = toGPServer(regReqQ, regRespQ);
    interface macRegClients = macRegClients_vec;
    interface phyRegClients = phyRegClients_vec;
endmodule

