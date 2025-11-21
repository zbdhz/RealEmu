// Copyright (C) 2025 Jingzhi Wang
// Email: jzwang@smail.nju.edu.cn
//
// This file is part of RealEmu.
//
// RealEmu is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// RealEmu is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with RealEmu.  If not, see <https://www.gnu.org/licenses/>.

import ClientServer::*;

//----------------------------------------------------
// treedepth = 2 
typedef 4 NODE_NUM;
typedef 2  GROUP_SIZE; 
//----------------------------------------------------

typedef 1024 MAX_DEV_NUM;

typedef 10 DEV_ID_WIDTH;
typedef 12 POWER_DB_WIDTH;  // (-128~127 dbm) * 256 = -32768~32767
typedef 8  POWER_DB_SHIFT_WIDTH; // 2^8 = 256
typedef 16 MPDU_LEN_WIDTH;
typedef 2  FC_TYPE_WIDTH;
typedef 4  FC_SUB_WIDTH;
typedef 16 FC_WIDTH;
typedef 16 DI_WIDTH;

typedef 4 MCS_WIDRH;

typedef 64 HOST_ADDR_WIDTH;

typedef enum {
    WIFI_11A = 0,
    WIFI_11B = 1,
    WIFI_11N = 2,
    WIFI_11AX = 3
}WifiProtocol deriving(Bits, Bounded, FShow);

// ============================ 802.11 MAC Types ==============================

typedef Bit#(DEV_ID_WIDTH)    MacId;
typedef Int#(POWER_DB_WIDTH)  PowerDb;  // (-128~127 dbm) * 256 = -32768~32767
typedef Bit#(FC_TYPE_WIDTH)   FrameType;
typedef Bit#(FC_SUB_WIDTH)    FrameSubType;
typedef Bit#(DI_WIDTH)        Duration;
typedef Bit#(MPDU_LEN_WIDTH)  MpduLen;
typedef Bit#(HOST_ADDR_WIDTH) MpduCacheAddr;

// 802.11 Frame Type
typedef 2'b00 FC_TYPE_MANAGEMENT;
typedef 2'b01 FC_TYPE_CONTROL;
typedef 2'b10 FC_TYPE_DATA;

// 802.11 Control Frame SubType
typedef 4'b1101 FC_CTRLSUB_ACK;
typedef 4'b1011 FC_CTRLSUB_RTS;
typedef 4'b1100 FC_CTRLSUB_CTS;

typedef Bit#(MCS_WIDRH) Mcs;

typedef 16 CW_WIDTH;
typedef Bit#(CW_WIDTH) ContWindow;
typedef Bit#(TLog#(CW_WIDTH)) ContWindowExp;
typedef Bit#(4) RetryTime;

typedef 16 TIMEUS_WIDTH;
typedef Bit#(TIMEUS_WIDTH) TimeUs;

typedef 16 TIMESLOT_WIDTH;
typedef Bit#(TIMESLOT_WIDTH) TimeSlot;

// 802.11 Mac Coniguration
typedef struct {
    TimeUs          slot;
    TimeUs          sifs;
    TimeUs          difs;
    TimeUs          eifs;
    TimeUs          sigTime;
    TimeUs          ofdmSymbolTime;
    TimeUs          maxNum;
    TimeUs          phyDelayTime;
    TimeUs          timeout;
    ContWindowExp   cwMin;
    ContWindowExp   cwMax;
    MpduLen         rtsThreshold;
    RetryTime       retryLimit;
    Bool            navEn;
    Bool            txopEn;
    Bool            filterEn;
}MacConfig deriving(Eq, Bits, Bounded, FShow);

function MacConfig getDefaultMacCfg();
    return MacConfig{
        // 802.11a setting
        slot: 9,
        sifs: 16,
        difs: 34,         
        eifs: 94,
        sigTime: 20,
        ofdmSymbolTime: 4,
        maxNum: 6,
        phyDelayTime: 25,
        // default
        timeout: 300,
        retryLimit: 6,
        rtsThreshold: 1400,
        // exp value
        cwMin: 4,  //15
        cwMax: 10, //1023
        // enable
        filterEn: True,
        txopEn: False, // not supported yet
        navEn: True
    };
endfunction

// Csma FSM Staus
typedef enum{
    CSMA_IDLE,
    CSMA_BACKOFF_IFS,
    CSMA_BACKOFF,
    CSMA_SUSPEND,
    CSMA_BUSY,
    CSMA_DONE
}CsmaState deriving(Eq, Bits, FShow); 

// DCF FSM Status
typedef enum {
    DCF_IDLE,
    DCF_WAIT_BACKOFF,
    DCF_RECV_CTSACK
} DcfState deriving (Bits, Eq, FShow);

typedef enum {
    NT_IDLE,
    // Send Logic
    NT_SEND_RTS,
    NT_RECV_CTS,
    NT_SEND_DATA,
    NT_RECV_ACK,
    // Recv Logic
    NT_SEND_CTS,
    NT_RECV_DATA,
    NT_SEND_ACK
} DcfNextTask deriving(Eq, Bits, FShow); 

typedef struct {
    CsmaState backOffState;
    DcfState dcfState;
}MacStatus deriving(Eq, Bits, FShow);

typedef struct {
    PowerDb power;
    Mcs     mcs;
}RfParam deriving(Eq, Bits, Bounded, FShow);

function RfParam getEmptyRfParam();
    return RfParam{power: 0, mcs: 0};
endfunction

function RfParam getDefaultRfParam(); // 包能被感应到
    return RfParam{power: 31*32, mcs: 0};
endfunction

typedef struct {
    // Mac Header
    FrameType frameType;
    FrameSubType frameSubType;
    Duration duration;
    // For sw operation
    MpduLen  length;
    MpduCacheAddr cacheAddr;
} MpduDigest deriving(Eq, Bits, Bounded, FShow);

function MpduDigest getEmptyMpduDigest();
    return MpduDigest{frameType: 0, frameSubType: 0, duration: 0, length: 0, cacheAddr: 0};
endfunction

function MpduDigest getDefaultMpduDigest();
    return MpduDigest{frameType: 0, frameSubType: 0, duration: 20, length: 0, cacheAddr: 0};
endfunction


// A digest of 802.11 MPDU from upper nodes
typedef struct {
    // Translated from Mac Addr to Id by driver
    MacId srcMacId;
    MacId dstMacId;
    // RF Parameter
    RfParam rfParam;
    // Mpdu Digest
    MpduDigest mpduDigest;
    // Event Status
    Bool status;
}MacEvent deriving(Eq, Bits, Bounded, FShow);

function MacEvent getEmptyMacEvent();
    return MacEvent{
        srcMacId  : 0, 
        dstMacId  : 0, 
        rfParam   : getEmptyRfParam, 
        mpduDigest: getEmptyMpduDigest,
        status    : False
    };
endfunction

function MacEvent getDefaultMacEvent();
    return MacEvent{
        srcMacId  : 0, 
        dstMacId  : 0, 
        rfParam   : getDefaultRfParam, 
        mpduDigest: getDefaultMpduDigest,
        status    : False
    };
endfunction

typedef struct {
} GenericResp deriving(Eq, Bits, Bounded, FShow);

typedef Server#(MacEvent, GenericResp) MacSrv;
typedef Client#(MacEvent, GenericResp) MacClt;

typedef 200 US_CYCLES;


// ========================================= Phy Types ====================================
typedef 16 RSSI_WIDTH;
typedef Bit#(RSSI_WIDTH) RSSI;

typedef 16 PPDU_LEN_WIDTH;
typedef Bit#(16) PpduLen;

typedef MacId PhyId;

typedef enum {
    PHY_IDLE, 
    PHY_TX, 
    PHY_SYNC, 
    PHY_RX
}PhyFsmState deriving(Eq, Bits, Bounded, FShow);

// For Mac
typedef struct {
    Bool cca;
    Bool fcsEn;
    Bool fcsCorrect;
}PhyStatus deriving(Eq, Bits, Bounded, FShow);

typedef struct {
    RSSI rssi;
    PowerDb rxPower;
    Bool cca;
    Bool fcsCorrect;
    PhyFsmState state;
}PhyFullStatus deriving(Eq, Bits, Bounded, FShow);

typedef struct {
    PhyId srcPhyId;
    PhyId dstPhyId;
    RfParam rfParam;
    PpduLen ppduLen;
    MpduDigest mpduDigest;
}PhyEvent deriving(Eq, Bits, Bounded, FShow);

function PhyEvent getEmptyPhyEvent();
    return PhyEvent{
        srcPhyId  : 0, 
        dstPhyId  : 0, 
        rfParam   : getEmptyRfParam, 
        ppduLen   : 0, 
        mpduDigest: getEmptyMpduDigest};
endfunction

typedef Server#(PhyEvent, GenericResp) PhySrv;
typedef Client#(PhyEvent, GenericResp) PhyClt;

// ======================================== Channel Types ====================================

typedef 10 DISTANCE_WIDTH;
typedef Bit#(DISTANCE_WIDTH) NodeDistance;

typedef Bit#(3) LogDistParaN;
typedef Bit#(8) LogDistPataL0;

typedef struct {
    LogDistParaN  n;
    LogDistPataL0 l0;
}LogDistanceParam deriving(Eq, Bits, Bounded, FShow);

typedef struct {
    PhyId srcPhyId;
    PhyId dstPhyId;
    NodeDistance distance;
}ChannelCfg deriving(Eq, Bits, Bounded, FShow);

function ChannelCfg getEmptyChannelCfg();
    return ChannelCfg{
        srcPhyId  : 0, 
        dstPhyId  : 0, 
        distance  : 1};
endfunction

typedef Server#(ChannelCfg, GenericResp) ChanSrv;
typedef Client#(ChannelCfg, GenericResp) ChanClt;

// ======================================== Bridge Types ====================================

typedef 1 CONTROL_FLAG_WIDTH;
typedef 7 NOTUSED_FLAG_WIDTH;
typedef 504 UndefinedPart_WIDTH;

typedef Bit#(CONTROL_FLAG_WIDTH) CONTROL_FLAG;
typedef Bit#(NOTUSED_FLAG_WIDTH) NOTUSED_FLAG;
typedef Bit#(UndefinedPart_WIDTH) UNDEFINED_PART;

typedef struct {
    CONTROL_FLAG control;
    NOTUSED_FLAG notUsed;
} BridgeTag deriving(Eq, Bits, Bounded, FShow);

function BridgeTag getEmptyBridgeTag();
    return BridgeTag{
        control: 0,
        notUsed: 0};
endfunction

typedef struct {
    MacEvent macEvent;
    BridgeTag bridgeTag;//调换控制帧的位置，确保数据面的对齐
} MacBridge_TOP deriving(Eq, Bits, Bounded, FShow);

typedef struct {
    ChannelCfg channelCfg;
    BridgeTag bridgeTag;//调换控制帧的位置，确保数据面的对齐
} CfgBridge_TOP deriving(Eq, Bits, Bounded, FShow);

typedef struct {
    BridgeTag bridgeTag;
    UNDEFINED_PART undefinedPart;
} CommonBridge_TOP deriving(Eq, Bits, Bounded, FShow);
