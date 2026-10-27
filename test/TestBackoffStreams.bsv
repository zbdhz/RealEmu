import GetPut::*;
import Vector::*;
import Types::*;
import CsmaUtils::*;

// 同步请求下，各节点不应产生整段相同的退避序列。旧的统一种子+低2位ID混合
// 会让相差4的节点锁步；隐藏节点无法彼此载波侦听，会重复发生同组碰撞。
module mkTestBackoffStreams(Empty);
    Vector#(NODE_NUM, ExpBackOffGenerator) generator <- genWithM(mkExpBackoffGenerator);
    Vector#(NODE_NUM, Reg#(Bit#(128))) signature <- replicateM(mkReg(0));
    Reg#(UInt#(6)) count <- mkReg(0);
    rule draw(count < 32);
        for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1) begin
            let slot <- generator[i].next.get;
            signature[i] <= (signature[i] << 4) | zeroExtend(pack(slot));
        end
        count <= count + 1;
    endrule
    rule check(count == 32);
        Bool independent = True;
        for (Integer i = 0; i < valueOf(NODE_NUM); i = i + 1)
            for (Integer j = i + 1; j < valueOf(NODE_NUM); j = j + 1)
                if (signature[i] == signature[j]) begin
                    independent = False;
                    $display("BACKOFF_DUPLICATE node=%0d,%0d signature=%h", i, j, signature[i]);
                end
        if (independent) $display("TEST_PASS backoff_streams 16 distinct 32-draw streams");
        else $display("TEST_FAIL backoff_streams correlated nodes");
        $finish(independent ? 0 : 1);
    endrule
endmodule
