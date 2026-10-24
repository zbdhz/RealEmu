import Types::*;
import FrameTiming::*;
import Vector::*;
module mkTestFrameTiming(Empty);
    Reg#(Bit#(16)) len <- mkReg(0);
    Reg#(Mcs) mcs <- mkReg(0);
    rule check;
        Vector#(8,UInt#(32)) rates = newVector;
        rates[0]=24; rates[1]=36; rates[2]=48; rates[3]=72; rates[4]=96; rates[5]=144; rates[6]=192; rates[7]=216;
        UInt#(32) bits = 8*zeroExtend(unpack(len))+22;
        UInt#(32) expected = 20+4*((bits+rates[mcs]-1)/rates[mcs]);
        if (frameTimeUs(len,mcs) != expected || symbolsToCycles(ofdmSymbols(len,mcs)) != expected*250) begin
            $display("FAIL airtime len=%0d mcs=%0d",len,mcs); $finish(1);
        end
        len <= len+1;
        if(len == 65535) begin
            $display("PASS exhaustive airtime MCS%0d: 65536 lengths",mcs);
            if(mcs == 7) begin
                let cfg=getDefaultMacCfg;
                let f=getEmptyMacEvent; f.mpduDigest.length=1038; f.rfParam.mcs=7;
                if(frameTimeUs(20,0)!=52 || frameTimeUs(14,0)!=44 || frameTimeUs(14,4)!=28 ||
                   frameTimeUs(1038,7)!=176 || frameTimeUs(1064,7)!=180 ||
                   dataDuration(cfg)!=60 || rtsDuration(f,cfg)!=312 || ctsDuration(312,cfg)!=252 || ctsDuration(0,cfg)!=0 ||
                   timeReached('hfffffff0,10) || !timeReached(10,'hfffffff0)) begin
                    $display("FAIL timing/Duration/wrap reference"); $finish(1);
                end
                cfg.controlMcs=4;
                if(dataDuration(cfg)!=44 || rtsDuration(f,cfg)!=280 || ctsDuration(280,cfg)!=236) begin
                    $display("FAIL 24Mbps control reservation"); $finish(1);
                end
                $display("PASS frame timing: all 524288 length/rate pairs, control rates, Duration, wrap"); $finish(0);
            end
            else mcs <= mcs+1;
        end
    endrule
endmodule
