import GetPut::*;
import Connectable::*;
import ClientServer::*;
import BRAM::*;
import Vector::*;
import FIFOF::*;
import FIFO::*;
import StmtFSM::*;
import Axi4LiteTypes::*;

import Types::*;

// ================================================================
// 地址空间常量定义 (符合XDMA的2MB AXI-Lite空间)
// ================================================================
typedef 32 AXI_ADDR_WIDTH;
typedef 32 AXI_DATA_WIDTH;

// 总地址空间: 2MB = 0x200000
parameter Bit#(32) TOTAL_SPACE_SIZE = 32'h200000;

// 系统预留空间: 前1MB (0x000000 ~ 0x0FFFFF)
parameter Bit#(32) SYSTEM_BASE_ADDR = 32'h000000;
parameter Bit#(32) SYSTEM_SPACE_SIZE = 32'h100000;

// 节点空间: 后1MB (0x100000 ~ 0x1FFFFF)
// 1024个节点，每个节点1KB (0x400字节)
parameter Bit#(32) NODE_BASE_ADDR = 32'h100000;
parameter Bit#(32) NODE_SPACE_SIZE = 32'h100000;
parameter Integer MAX_NODES = 1024;
parameter Bit#(32) NODE_SIZE = 32'h400;  // 1024 bytes per node

// 每个节点内部划分:
// - MAC配置空间: 512字节 (0x000 ~ 0x1FF)
// - PHY配置空间: 512字节 (0x200 ~ 0x3FF)
parameter Bit#(32) MAC_CONFIG_SIZE = 32'h200;  // 512 bytes
parameter Bit#(32) PHY_CONFIG_SIZE = 32'h200;  // 512 bytes

// Demo支持的节点数
parameter Integer DEMO_NODE_COUNT = 128;

// ================================================================
// 节点控制管理器接口
// ================================================================
interface NodeControlManager_IFC;
    interface RawAxi4LiteSlave axiLiteSlave;
    interface Vector#(DEMO_NODE_COUNT, MacConfigClt) macConfigClients;
    interface Vector#(DEMO_NODE_COUNT, MacStatusClt) macStatusClients;
    interface Vector#(DEMO_NODE_COUNT, PhyStatusClt) phyStatusClients;
endinterface

// ================================================================
// AXI-Lite节点控制管理器模块
// ================================================================
module mkAxiLiteNodeControlManager#(Integer nodeCount)(NodeControlManager_IFC)
    provisos (Add#(a__, 10, 32));

    // 状态寄存器
    Reg#(Bit#(AXI_ADDR_WIDTH)) currAddrReg <- mkReg(0);
    Reg#(Bit#(AXI_DATA_WIDTH)) currDataReg <- mkReg(0);
    Reg#(Bool) isWriteOp <- mkReg(False);
    Reg#(Maybe#(Bit#(AXI4_RESP_WIDTH))) respMuxReg <- mkReg(tagged Invalid);

    // 响应FIFO用于存储从节点返回的数据
    Vector#(DEMO_NODE_COUNT, FIFO#(MacConfigRes)) macConfigRespQs <- replicateM(mkFIFO);
    Vector#(DEMO_NODE_COUNT, FIFO#(MacStatusRes)) macStatusRespQs <- replicateM(mkFIFO);
    Vector#(DEMO_NODE_COUNT, FIFO#(PhyStatusRes)) phyStatusRespQs <- replicateM(mkFIFO);

    // 请求状态跟踪
    Reg#(Maybe#(Tuple3#(Bit#(10), Bit#(10), Bit#(32)))) pendingReqReg <- mkReg(tagged Invalid);

    // ================================================================
    // 地址解码函数
    // 输入: 32位地址
    // 输出: (是否有效节点索引, 节点索引, 节点内偏移)
    // ================================================================
    function Tuple3#(Bool, Bit#(10), Bit#(10)) decodeNodeAddress(Bit#(32) addr);
        Bool isValidSystem = (addr < SYSTEM_SPACE_SIZE);
        Bool isValidNodeSpace = (addr >= NODE_BASE_ADDR) && (addr < TOTAL_SPACE_SIZE);

        if (isValidSystem) begin
            // 系统空间: 返回无效节点索引，使用偏移量标识
            return tuple3(True, 10'h3FF, truncate(addr));
        end else if (isValidNodeSpace) begin
            // 节点空间
            Bit#(32) nodeRelativeAddr = addr - NODE_BASE_ADDR;
            Bit#(10) nodeIdx = truncate(nodeRelativeAddr >> 10);  // 除以1024
            Bit#(10) nodeOffset = truncate(nodeRelativeAddr);     // 模1024

            Bool validNode = (nodeIdx < fromInteger(nodeCount));
            return tuple3(validNode, nodeIdx, nodeOffset);
        end else begin
            // 无效地址
            return tuple3(False, 10'h3FF, 10'h000);
        end
    endfunction

    // ================================================================
    // 系统空间读取处理
    // ================================================================
    function ActionValue#(Tuple2#(Bit#(32), Bit#(AXI4_RESP_WIDTH))) handleSystemRead(Bit#(32) addr);
        actionvalue
            Bit#(AXI4_RESP_WIDTH) resp = AXI4_OKAY;
            Bit#(32) readData = 0;

            case (addr)
                32'h000000: readData = zeroExtend(pack(nodeCount));  // 节点数量
                32'h000004: readData = 32'h00000001;                  // 版本号
                32'h000008: readData = 32'h00000001;                  // 状态寄存器
                default: begin
                    resp = AXI4_DECERR;
                    readData = 0;
                end
            endcase

            $display("[AXI-Lite] System Read - addr: %h, data: %h", addr, readData);
            return tuple2(readData, resp);
        endactionvalue
    endfunction

    // ================================================================
    // 系统空间写入处理
    // ================================================================
    function ActionValue#(Bit#(AXI4_RESP_WIDTH)) handleSystemWrite(Bit#(32) addr, Bit#(32) data);
        actionvalue
            Bit#(AXI4_RESP_WIDTH) resp = AXI4_OKAY;

            case (addr)
                32'h000008: begin
                    // 全局控制寄存器
                    $display("[AXI-Lite] System Write - Global Ctrl: %h", data);
                end
                default: begin
                    resp = AXI4_DECERR;
                    $display("[AXI-Lite] System Write Error - addr: %h, data: %h", addr, data);
                end
            endcase

            return resp;
        endactionvalue
    endfunction

    // ================================================================
    // MAC配置寄存器读取/写入处理
    // ================================================================
    function Tuple2#(MacConfigReq, Bit#(10)) buildMacConfigReq(Bit#(10) nodeIdx, Bit#(10) offset, Bit#(32) writeData, Bool isWrite);
        Bool isRead = !isWrite;
        Bit#(10) regOffset = offset >> 2;  // 转换为32位寄存器索引

        MacConfigReq req = MacConfigReq {
            macReqTag: MACReqTag { rwMode: isRead ? MOD_READ : MOD_WRITE },
            macConfig: getDefaultMacCfg()
        };

        if (!isRead) begin
            // 构建写入请求，需要解析writeData并设置到macConfig中
            case (regOffset)
                10'h00: req.macConfig.slot = unpack(writeData);
                10'h01: req.macConfig.sifs = unpack(writeData);
                10'h02: req.macConfig.difs = unpack(writeData);
                10'h03: req.macConfig.eifs = unpack(writeData);
                10'h04: req.macConfig.sigTime = unpack(writeData);
                10'h05: req.macConfig.ofdmSymbolTime = unpack(writeData);
                10'h06: req.macConfig.maxNum = unpack(writeData);
                10'h07: req.macConfig.phyDelayTime = unpack(writeData);
                10'h08: req.macConfig.timeout = unpack(writeData);
                10'h09: begin
                    req.macConfig.cwMin = unpack(writeData[15:8]);
                    req.macConfig.cwMax = unpack(writeData[7:0]);
                end
                10'h0A: req.macConfig.rtsThreshold = unpack(writeData);
                10'h0B: req.macConfig.retryLimit = unpack(writeData[3:0]);
                10'h0C: begin
                    req.macConfig.navEn = unpack(writeData[31]);
                    req.macConfig.txopEn = unpack(writeData[30]);
                    req.macConfig.filterEn = unpack(writeData[29]);
                end
                default: req = getReadMacConfigReq();  // 无效偏移，返回读取请求
            endcase
        end

        return tuple2(req, regOffset);
    endfunction

    function Bit#(32) extractMacConfigData(MacConfig cfg, Bit#(10) regOffset);
        case (regOffset)
            10'h00: return pack(cfg.slot);
            10'h01: return pack(cfg.sifs);
            10'h02: return pack(cfg.difs);
            10'h03: return pack(cfg.eifs);
            10'h04: return pack(cfg.sigTime);
            10'h05: return pack(cfg.ofdmSymbolTime);
            10'h06: return pack(cfg.maxNum);
            10'h07: return pack(cfg.phyDelayTime);
            10'h08: return pack(cfg.timeout);
            10'h09: return {0, pack(cfg.cwMin), pack(cfg.cwMax)};
            10'h0A: return pack(cfg.rtsThreshold);
            10'h0B: return {0, 0, 0, pack(cfg.retryLimit)};
            10'h0C: return {pack(cfg.navEn), pack(cfg.txopEn), pack(cfg.filterEn), 29'b0};
            default: return 0;
        endcase
    endfunction

    // ================================================================
    // MAC状态寄存器读取处理 (只读)
    // ================================================================
    function Tuple2#(MacStatusReq, Bit#(10)) buildMacStatusReq(Bit#(10) nodeIdx, Bit#(10) offset, Bool isWrite);
        Bit#(10) regOffset = offset >> 2;
        MacStatusReq req = MacStatusReq {
            macReqTag: MACReqTag { rwMode: MOD_READ }
        };
        return tuple2(req, regOffset);
    endfunction

    function Bit#(32) extractMacStatusData(MacStatus status, Bit#(10) regOffset);
        case (regOffset)
            10'h00: return {0, pack(status.backOffState), pack(status.dcfState)};
            default: return 0;
        endcase
    endfunction

    // ================================================================
    // PHY状态寄存器读取处理 (只读)
    // ================================================================
    function Tuple2#(PhyStatusReq, Bit#(10)) buildPhyStatusReq(Bit#(10) nodeIdx, Bit#(10) offset, Bool isWrite);
        Bit#(10) regOffset = offset >> 2;
        PhyStatusReq req = PhyStatusReq {
            phyReqTag: PhyReqTag { rwMode: MOD_READ }
        };
        return tuple2(req, regOffset);
    endfunction

    function Bit#(32) extractPhyStatusData(PhyStatus status, Bit#(10) regOffset);
        case (regOffset)
            10'h00: return {pack(status.state), pack(status.cca), pack(status.fcsEn),
                           pack(status.fcsCorrect), pack(status.txStart), pack(status.txEnd),
                           pack(status.rxStart), pack(status.rxEnd), 24'b0};
            default: return 0;
        endcase
    endfunction

    // ================================================================
    // 等待响应规则
    // ================================================================
    rule waitMacConfigResp if (isValid(pendingReqReg));
        let {nodeIdx, reqType, regOffset} = fromJust(pendingReqReg);
        if (reqType == 10'h00) begin  // MAC配置请求
            if (macConfigRespQs[nodeIdx].notEmpty) begin
                let resp <- toGet(macConfigRespQs[nodeIdx]).get();
                currDataReg <= extractMacConfigData(resp.macConfig, regOffset);
                respMuxReg <= tagged Valid AXI4_OKAY;
                pendingReqReg <= tagged Invalid;
                $display("[AXI-Lite] MAC Config Resp - Node: %d, Reg: %h", nodeIdx, regOffset);
            end
        end else if (reqType == 10'h01) begin  // MAC状态请求
            if (macStatusRespQs[nodeIdx].notEmpty) begin
                let resp <- toGet(macStatusRespQs[nodeIdx]).get();
                currDataReg <= extractMacStatusData(resp, regOffset);
                respMuxReg <= tagged Valid AXI4_OKAY;
                pendingReqReg <= tagged Invalid;
                $display("[AXI-Lite] MAC Status Resp - Node: %d, Reg: %h", nodeIdx, regOffset);
            end
        end else if (reqType == 10'h02) begin  // PHY状态请求
            if (phyStatusRespQs[nodeIdx].notEmpty) begin
                let resp <- toGet(phyStatusRespQs[nodeIdx]).get();
                currDataReg <= extractPhyStatusData(resp.phyStatus, regOffset);
                respMuxReg <= tagged Valid AXI4_OKAY;
                pendingReqReg <= tagged Invalid;
                $display("[AXI-Lite] PHY Status Resp - Node: %d, Reg: %h", nodeIdx, regOffset);
            end
        end
    endrule

    // ================================================================
    // AXI-Lite从接口实现
    // ================================================================
    interface RawAxi4LiteSlave axiLiteSlave;
        interface RawAxi4LiteWrSlave wrSlave;
            method Action awValidData(Bool awValid, Bit#(AXI_ADDR_WIDTH) awAddr, Bit#(AXI4_PROT_WIDTH) awProt);
                if (awValid) begin
                    currAddrReg <= awAddr;
                    isWriteOp <= True;
                    $display("[AXI-Lite] AWVALID - addr: %h", awAddr);
                end
            endmethod

            method Bool awReady();
                return !isValid(pendingReqReg);  // 忙时不能接收新请求
            endmethod

            method Action wValidData(Bool wValid, Bit#(AXI_DATA_WIDTH) wData, Bit#(TDiv#(AXI_DATA_WIDTH, 8)) wStrb);
                if (wValid && isWriteOp && !isValid(pendingReqReg)) begin
                    let {isValidNode, nodeIdx, nodeOffset} = decodeNodeAddress(currAddrReg);
                    Bit#(AXI4_RESP_WIDTH) resp = AXI4_OKAY;

                    if (!isValidNode) begin
                        resp <- handleSystemWrite(currAddrReg, wData);
                        respMuxReg <= tagged Valid resp;
                    end else if (nodeIdx == 10'h3FF) begin
                        resp <- handleSystemWrite(nodeOffset, wData);
                        respMuxReg <= tagged Valid resp;
                    end else begin
                        // 节点空间访问
                        if (nodeOffset < MAC_CONFIG_SIZE) begin
                            // MAC配置空间
                            let {req, regOffset} = buildMacConfigReq(nodeIdx, nodeOffset, wData, True);
                            // 发送请求到MAC层
                            // 这里需要在外部连接时处理
                            $display("[AXI-Lite] MAC Write - Node: %d, Offset: %h, Data: %h", nodeIdx, nodeOffset, wData);
                            // 暂时直接更新响应，等连接后改为实际通信
                            respMuxReg <= tagged Valid AXI4_OKAY;
                        end else if (nodeOffset < (MAC_CONFIG_SIZE + PHY_CONFIG_SIZE)) begin
                            // PHY配置空间 - 只读，忽略写入
                            $display("[AXI-Lite] PHY Write (ReadOnly) - Node: %d, Offset: %h", nodeIdx, nodeOffset);
                            respMuxReg <= tagged Valid AXI4_OKAY;
                        end else begin
                            // 控制寄存器空间
                            resp = AXI4_DECERR;
                            respMuxReg <= tagged Valid resp;
                        end
                    end
                end
            endmethod

            method Bool wReady();
                return True;
            endmethod

            method Bool bValid();
                return isValid(respMuxReg) && isWriteOp;
            endmethod

            method Bit#(AXI4_RESP_WIDTH) bResp();
                return fromMaybe(AXI4_OKAY, respMuxReg);
            endmethod

            method Action bReady(Bool rdy);
                if (rdy && isValid(respMuxReg)) begin
                    respMuxReg <= tagged Invalid;
                    isWriteOp <= False;
                end
            endmethod
        endinterface

        interface RawAxi4LiteRdSlave rdSlave;
            method Action arValidData(Bool arValid, Bit#(AXI_ADDR_WIDTH) arAddr, Bit#(AXI4_PROT_WIDTH) arProt);
                if (arValid && !isValid(pendingReqReg)) begin
                    currAddrReg <= arAddr;
                    isWriteOp <= False;

                    let {isValidNode, nodeIdx, nodeOffset} = decodeNodeAddress(arAddr);
                    Bit#(AXI4_RESP_WIDTH) resp = AXI4_OKAY;

                    if (!isValidNode) begin
                        let {readData, readResp} <- handleSystemRead(arAddr);
                        currDataReg <= readData;
                        respMuxReg <= tagged Valid readResp;
                    end else if (nodeIdx == 10'h3FF) begin
                        let {readData, readResp} <- handleSystemRead(nodeOffset);
                        currDataReg <= readData;
                        respMuxReg <= tagged Valid readResp;
                    end else begin
                        // 节点空间访问
                        if (nodeOffset < MAC_CONFIG_SIZE) begin
                            // MAC配置空间
                            let {req, regOffset} = buildMacConfigReq(nodeIdx, nodeOffset, 0, False);
                            // 标记等待响应
                            pendingReqReg <= tagged Valid tuple3(nodeIdx, 10'h00, regOffset);
                            $display("[AXI-Lite] MAC Read Req - Node: %d, Offset: %h", nodeIdx, nodeOffset);
                        end else if (nodeOffset < (MAC_CONFIG_SIZE + PHY_CONFIG_SIZE)) begin
                            // PHY状态空间
                            let {req, regOffset} = buildPhyStatusReq(nodeIdx, nodeOffset, False);
                            pendingReqReg <= tagged Valid tuple3(nodeIdx, 10'h02, regOffset);
                            $display("[AXI-Lite] PHY Read Req - Node: %d, Offset: %h", nodeIdx, nodeOffset);
                        end else begin
                            // 控制寄存器空间 - MAC状态
                            let {req, regOffset} = buildMacStatusReq(nodeIdx, nodeOffset, False);
                            pendingReqReg <= tagged Valid tuple3(nodeIdx, 10'h01, regOffset);
                            $display("[AXI-Lite] MAC Status Read Req - Node: %d, Offset: %h", nodeIdx, nodeOffset);
                        end
                    end
                end
            endmethod

            method Bool arReady();
                return !isValid(pendingReqReg);
            endmethod

            method Bool rValid();
                return isValid(respMuxReg) && !isWriteOp;
            endmethod

            method Bit#(AXI4_RESP_WIDTH) rResp();
                return fromMaybe(AXI4_OKAY, respMuxReg);
            endmethod

            method Bit#(AXI_DATA_WIDTH) rData();
                return currDataReg;
            endmethod

            method Action rReady(Bool rdy);
                if (rdy && isValid(respMuxReg)) begin
                    respMuxReg <= tagged Invalid;
                end
            endmethod
        endinterface
    endinterface

    // ================================================================
    // Client接口连接到MacCore和PhyCore
    // ================================================================
    // Client接口用于AXI-Lite控制器发送请求和接收响应
    interface macConfigClients = vec(
        for (Integer i = 0; i < DEMO_NODE_COUNT; i = i + 1)
            interface MacConfigClt;
                interface Put request;
                    method Action put(MacConfigReq req);
                        macConfigRespQs[i].enq(MacConfigRes{macConfig: req.macConfig});
                    endmethod
                endinterface
                interface Get response = toGet(macConfigRespQs[i]);
            endinterface
    );

    interface macStatusClients = vec(
        for (Integer i = 0; i < DEMO_NODE_COUNT; i = i + 1)
            interface MacStatusClt;
                interface Put request;
                    method Action put(MacStatusReq req);
                        macStatusRespQs[i].enq(MacStatusRes{dcfState: DCF_IDLE, dcfNextTask: NT_IDLE});
                    endmethod
                endinterface
                interface Get response = toGet(macStatusRespQs[i]);
            endinterface
    );

    interface phyStatusClients = vec(
        for (Integer i = 0; i < DEMO_NODE_COUNT; i = i + 1)
            interface PhyStatusClt;
                interface Put request;
                    method Action put(PhyStatusReq req);
                        phyStatusRespQs[i].enq(PhyStatusRes{phyStatus: getEmptyPhyStatus()});
                    endmethod
                endinterface
                interface Get response = toGet(phyStatusRespQs[i]);
            endinterface
    );

    // Server接口用于直接连接到MacCore和PhyCore
    // 外部模块（如BsvTop）应该直接将NodeControlManager_IFC的Server接口
    // 连接到对应的MacCore/PhyCore的Server接口
    // 例如：mkConnection(ctrl.macConfigSrvs[i], macCores[i].macConfigSrv)

endmodule

// ================================================================
// 便捷连接函数
// ================================================================

// 连接MAC Core到控制管理器
// 使用mkConnection将控制器的Client接口连接到MAC Core的Server接口
module mkConnectMacCoreToCtrl#(
    Integer nodeIdx,
    MacCore macCore,
    NodeControlManager_IFC ctrl
)(Empty);
    // mkConnection自动将Client的Put连接到Server的Get，将Client的Get连接到Server的Put
    mkConnection(ctrl.macConfigClients[nodeIdx], macCore.macConfigSrv);
    mkConnection(ctrl.macStatusClients[nodeIdx], macCore.macStatusSrv);
endmodule

// 连接PHY Core到控制管理器
module mkConnectPhyCoreToCtrl#(
    Integer nodeIdx,
    PhyCore phyCore,
    NodeControlManager_IFC ctrl
)(Empty);
    mkConnection(ctrl.phyStatusClients[nodeIdx], phyCore.phyStatusSrv);
endmodule

// 批量连接所有节点
module mkConnectAllNodes#(
    Vector#(DEMO_NODE_COUNT, MacCore) macCores,
    Vector#(DEMO_NODE_COUNT, PhyCore) phyCores,
    NodeControlManager_IFC ctrl
)(Empty);
    for (Integer i = 0; i < DEMO_NODE_COUNT; i = i + 1) begin
        mkConnection(ctrl.macConfigClients[i], macCores[i].macConfigSrv);
        mkConnection(ctrl.macStatusClients[i], macCores[i].macStatusSrv);
        mkConnection(ctrl.phyStatusClients[i], phyCores[i].phyStatusSrv);
    end
endmodule
