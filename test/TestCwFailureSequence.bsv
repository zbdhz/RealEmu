import GetPut::*;
import Types::*;
import CsmaUtils::*;

// 验证ns-3站级CW序列，不把MPDU的第7次失败当成成功/reset。
// 每档采128个值，同时检查上界和高半区，避免随机值恰好偏小掩盖错误窗口。
module mkTestCwFailureSequence(Empty);
    let generator <- mkExpBackoffGenerator(3);
    Reg#(UInt#(2)) phase <- mkReg(0);
    Reg#(UInt#(5)) failures <- mkReg(0);
    Reg#(UInt#(8)) draws <- mkReg(0);
    Reg#(Bool) highSeen <- mkReg(False);
    Reg#(Bool) afterSuccess <- mkReg(False);
    rule configure(phase == 0);
        let cfg = getDefaultMacCfg;
        cfg.cwMin = 4; cfg.cwMax = 10; cfg.retryLimit = 6;
        generator.putmaccfg.put(cfg);
        phase <= 1;
    endrule
    rule sample(phase == 1);
        let value <- generator.next.get;
        UInt#(16) slot = zeroExtend(unpack(pack(value)));
        UInt#(5) stationFailures = failures % 8;
        UInt#(5) exponent = stationFailures < 6 ? 4 + stationFailures : 10;
        UInt#(16) bound = 1 << exponent;
        Bool high = highSeen || slot >= (bound >> 1);
        if (slot >= bound) begin
            $display("TEST_FAIL cw_failure_sequence failures=%0d expected_bound=%0d value=%0d", failures, bound, value);
            $finish(1);
        end
        highSeen <= high;
        draws <= draws + 1;
        if (draws == 127) begin
            if (!high) begin
                $display("TEST_FAIL cw_failure_sequence no_high_half failures=%0d expected_bound=%0d", failures, bound);
                $finish(1);
            end
            if (afterSuccess) begin
                $display("TEST_PASS cw_failure_sequence CW=15,31,63,127,255,511,1023,1023,15 across MPDU boundary; success resets CW");
                $finish(0);
            end
            else if (failures == 14) phase <= 3;
            else phase <= 2;
        end
    endrule
    rule failAttempt(phase == 2);
        generator.incrCW;
        failures <= failures + 1;
        draws <= 0; highSeen <= False; phase <= 1;
    endrule
    rule successfulAttempt(phase == 3);
        generator.resetCW;
        failures <= 0; draws <= 0; highSeen <= False;
        afterSuccess <= True; phase <= 1;
    endrule
endmodule
