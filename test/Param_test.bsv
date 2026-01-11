
// parameter 定义
// typedef 8'd16 P_W;
typedef 8 LEN;
Bit#(8)  pw  = 8'd16;
// Integer  p_c  = 8;
// typedef enum {
//     // PW1   = 8'd16,
//     PW2  = 8'd16
// }PW deriving(Bits, Eq, FShow);
// 一个最简单的模块，包含 parameter 定义与使用
module mkTestParameter();

    // 使用 parameter 的寄存器
    Reg#(Bit#(LEN)) rWidth <- mkReg(pack(pw));
    // Reg#(Integer) rCount <- mkReg(p_c);

    // 简单 rule，证明 parameter 可以被综合和使用
    rule test_rule;
        rWidth <= rWidth + 1;
        $display("re:%d", rWidth);

        // rCount <= rCount + 1;
    endrule

    rule end_rule;
        if (rWidth == 4)
        $finish();
    endrule

endmodule


