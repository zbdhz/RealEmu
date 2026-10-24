// Two explicitly versioned error models: legacy frame PRR + strong overlap,
// and a duration-weighted chunk model whose table entries are BIT success
// probabilities. Never reuse a measured whole-packet PRR table as a BER table.
import Types::*;
import FrameTiming::*;
import GetPut::*;
import FIFOF::*;
import ClientServer::*;
import BRAM::*;
import PrimUtils::*;

// Positive linear power in units of 2^-24 mW. A 16-entry fractional log LUT
// bounds quantization to about 0.2 dB; no floating point or run-time division.
function UInt#(64) linearPower(PowerDb db);
    Int#(32) logq = ((signExtend(db) * 85) >> 5) + 6144;
    UInt#(6) exponent = truncate(unpack(pack(logq >> 8)));
    Bit#(4) fraction = truncate(pack(logq >> 4));
    UInt#(64) mantissa = 65536;
    case (fraction)
        1: mantissa=68438; 2: mantissa=71468; 3: mantissa=74632;
        4: mantissa=77936; 5: mantissa=81386; 6: mantissa=84990;
        7: mantissa=88758; 8: mantissa=92682; 9: mantissa=96785;
        10: mantissa=101070; 11: mantissa=105545; 12: mantissa=110218;
        13: mantissa=115098; 14: mantissa=120194; 15: mantissa=125514;
    endcase
    return (mantissa << exponent) >> 16;
endfunction

function Int#(16) powerDb(UInt#(64) power);
    UInt#(6) exponent = 0;
    for (Integer i=0; i<64; i=i+1) if (power >= (1 << i)) exponent = fromInteger(i);
    UInt#(64) norm = exponent >= 4 ? power >> (exponent - 4) : power << (4 - exponent);
    Bit#(4) fraction = truncate(pack(norm));
    Int#(32) logfraction = 0;
    case (fraction)
        1:logfraction=22; 2:logfraction=44; 3:logfraction=63; 4:logfraction=82;
        5:logfraction=100; 6:logfraction=118; 7:logfraction=134; 8:logfraction=150;
        9:logfraction=165; 10:logfraction=179; 11:logfraction=193; 12:logfraction=207;
        13:logfraction=220; 14:logfraction=232; 15:logfraction=244;
    endcase
    Int#(32) e = unpack(zeroExtend(pack(exponent)));
    return truncate((((e - 24) * 256 + logfraction) * 771) >> 11);
endfunction

function UInt#(16) probabilityProduct(UInt#(16) a, UInt#(16) b);
    UInt#(32) product = zeroExtend(a) * zeroExtend(b);
    return a == 65535 ? b : (b == 65535 ? a : truncate(product >> 16));
endfunction

function UInt#(32) codedBitsPerSymbol(Mcs mcs, Bool header);
    UInt#(32) ndbps = 24;
    if (!header) case (mcs)
        1:ndbps=36; 2:ndbps=48; 3:ndbps=72; 4:ndbps=96;
        5:ndbps=144; 6:ndbps=192; 7:ndbps=216;
    endcase
    return ndbps;
endfunction

typedef struct {
    AirFrame frame;
    UInt#(64) interference; // includes noise floor (1mW, matching legacy setup)
    UInt#(32) cycles;
    Bool header;
    Bool first;
    Bool last;
    Bool headerEnd;
    Bool collided;
    Bool bitModel;
} RxChunk deriving(Bits, Eq, FShow);
typedef struct {
    AirFrame frame;
    Bool header;
    Bool success;
    Bool collided;
} RxDecision deriving(Bits, Eq, FShow);
interface ReceptionModel;
    interface Put#(RxChunk) request;
    interface Get#(RxDecision) response;
    interface PerSrv perSrv;
endinterface
module mkReceptionModel#(Integer id)(ReceptionModel);
    FIFOF#(RxChunk) inputQ <- mkSizedFIFOF(64);
    FIFOF#(RxDecision) outputQ <- mkSizedFIFOF(8);
    FIFOF#(PerCfg) cfgQ <- mkFIFOF;
    FIFOF#(GenericResp) cfgResp <- mkFIFOF;
    BRAM2Port#(PerIn,PerOut) tableRam <- mkBRAM2Server(BRAM_Configure{
        memorySize:16384, loadFormat:tagged Hex "Per.mem", latency:2,
        outFIFODepth:4, allowWriteResponseBypass:False});
    Reg#(Bit#(2)) stage <- mkReg(0);
    Reg#(RxChunk) current <- mkRegU;
    Reg#(UInt#(16)) survival <- mkReg(65535);
    Reg#(UInt#(16)) factor <- mkReg(65535);
    Reg#(UInt#(16)) product <- mkReg(65535);
    Reg#(UInt#(32)) exponent <- mkReg(0);
    Reg#(UInt#(10)) bitRemainder <- mkReg(0);
    Reg#(Bool) collision <- mkReg(False);
    Reg#(UInt#(16)) random <- mkReg(fromInteger(12345 + id*977));
    Reg#(UInt#(16)) frameRandom <- mkReg(1);
    rule configure;
        let c = cfgQ.first; cfgQ.deq;
        tableRam.portA.request.put(BRAMRequest{write:True,responseOnWrite:False,address:c.perIn,datain:c.perOut});
        cfgResp.enq(GenericResp{});
    endrule
    rule beginChunk (stage == 0);
        let c = inputQ.first; inputQ.deq; current <= c;
        Int#(16) sinr = signExtend(c.frame.rfParam.power) - powerDb(c.interference);
        UInt#(14) index = sinr < -160 ? 0 : (sinr >= 960 ? 1119 : truncate(unpack(pack(sinr + 160))));
        UInt#(14) mcs = c.header ? 0 : zeroExtend(unpack(c.frame.rfParam.mcs));
        tableRam.portB.request.put(BRAMRequest{write:False,responseOnWrite:False,address:mcs*1120+index,datain:0});
        if (c.first) begin
            survival <= 65535; collision <= c.collided; bitRemainder <= 0;
            Bit#(16) r = pack(random);
            random <= unpack((r >> 1) ^ (r[0] == 1 ? 16'hB400 : 0));
            frameRandom <= random;
        end
        else collision <= collision || c.collided;
        stage <= 1;
    endrule
    rule lookup (stage == 1);
        let p <- tableRam.portB.response.get;
        factor <= p; product <= 65535;
        UInt#(64) weighted = zeroExtend(current.cycles) * zeroExtend(codedBitsPerSymbol(current.frame.rfParam.mcs,current.header)) + zeroExtend(bitRemainder);
        UInt#(64) divisor = fromInteger(4 * valueOf(US_CYCLES));
        UInt#(64) remainder = weighted % divisor;
        UInt#(32) bitCount = truncate(weighted/divisor);
        if(current.headerEnd || current.last) begin
            if(remainder != 0) bitCount = bitCount+1;
            bitRemainder <= 0;
        end
        else bitRemainder <= truncate(remainder);
        exponent <= current.bitModel ? bitCount : ((current.headerEnd || current.last) ? 1 : 0);
        stage <= 2;
    endrule
    rule multiply (stage == 2);
        if (exponent == 0) stage <= 3;
        else begin
            if (pack(exponent)[0] == 1) product <= probabilityProduct(product, factor);
            factor <= probabilityProduct(factor, factor); exponent <= exponent >> 1;
        end
    endrule
    rule finishChunk (stage == 3);
        let p = probabilityProduct(survival, product);
        survival <= p;
        Bool ok = p != 0 && (p == 65535 || p >= frameRandom) && (current.bitModel || !collision);
        if (current.headerEnd || current.last)
            outputQ.enq(RxDecision{frame:current.frame,header:current.headerEnd,success:ok,collided:collision});
        stage <= 0;
    endrule
    interface request = toPut(inputQ);
    interface response = toGet(outputQ);
    interface perSrv = toGPServer(cfgQ,cfgResp);
endmodule
