# D01—D03 死锁修复与仿真验证

日期：2026-10-25，Asia/Shanghai。基线：`1203808a7a0369772aaae87d53ae71e80b2d57b8`，分支 `hidden-node-16node-20261024-wcl`。

2026-10-26 增量说明：本文记录 D 批次在 200 cycles/µs 下的原始实施和证据。后续 T/C 批次已将生产时基统一为 250，并再次通过原有 24 个回归；当前源码范围、配置边界和最新结果见 [T01/T02、C01/C02 实施记录](bluespec-timing-config-fix-results-20261026.md)。

## 1. 修改范围

生产代码只修改 [MacCore.bsv](../src/MacCore.bsv) 和 [PhyCore.bsv](../src/PhyCore.bsv)。保持原 DCF/CSMA/PHY 状态枚举、外部接口、FIFO、mode0 整包判决和 200 cycles/µs 时基。

源码层面新增一个 3 位状态计数器 `pendingTxCountReg`、一个 Bool 标志 `responseWaitReg` 和三个 PulseWire，共新增 4 位持久状态，复用原有退避复位入口。没有新增发送事务表、数据 FIFO、模式寄存器或全局 watchdog。新增/调整的关键代码均有解释原因与握手边界的注释。

| 要求 | 具体改动 | 原因和作用 |
| --- | --- | --- |
| D01：请求接受与发送一致 | 将原 `handleLowMacTxReqQ` 的取请求、回复和信道入队移到 PHY_IDLE 中，与进入 PHY_TX 原子完成 | 忙时请求保存在原 FIFO，不再出现“信道已经收到帧，本地 PHY 却没有开始发送” |
| D01：同周期接收 | 已到达的强 RX 优先；弱于 CS 门限的 RX 不阻止 TX | 强接收不会吞掉发送启动；连续隐藏弱帧也不能仅靠 valid 饿死本机发送 |
| D01/D02：txEnd 宽度 | txEndReg 改为 mkDReg，独立恢复 False，去掉 IDLE 清零 | 下一次发送遭信道背压时，不会把旧 txEnd 延长成多拍 |
| D02：独立计时 | `updateResponseTimeouts` 独立采 txEnd、推进并饱和 ACK/CTS 计数器 | 普通寄存器访问、RX/TX 队列背压不再抢掉计时启动或暂停时间推进；满值不回绕为 0 |
| D02：完成归属 | 用 pendingTxCountReg 统计已入队但未结束的 TX；新的 RTS/DATA 等旧控制帧全部发完，CTS/ACK 仍可排队 | 信道背压下，旧 ACK/CTS 的 txEnd 不会被当成新 RTS/DATA 的完成；保留原缓冲能力，排队和自身空口时间不计入应答 timeout |
| D02：明确武装应答等待 | 仅 RTS/DATA 设置 responseWaitReg，空闲/完成路径清理 | 控制 ACK/CTS 不会启动下一次 DATA 的计时；避免短 timeout 下首次 DATA 尚未发送就被当成超时 |
| D03：完成保持 | 退避许可改为保持值，CSMA_DONE 单独用 `holdBackoffDone` 规则保持 | 错过一个周期不再永久失去 done；拆规则避免握手与 IFS/随机数规则形成调度环 |
| D03：原子消费 | 成功发送入队/明确结束分支调用已有 softRst；发送规则显式要求 done | FIFO 不接受时不确认 done；寄存器访问后仍能继续消费 |
| D03：调度优先级 | 已完成退避的消费优先于普通 TX 入队复制 | 持续输入不会让始终可执行的复制规则压制待发队头 |

应答计时仍以实际 TX_END 为起点；保留原 timeout 和重试配置。重试耗尽缺少高层 GenericResp 的 M04 问题本批未扩展处理，测试明确区分“MAC 已丢弃队头”与“收到成功 ACK 完成通知”。

## 2. 自动化测试入口

新增以下测试源和脚本：

- [TestMacPhyDeadlock.bsv](../test/TestMacPhyDeadlock.bsv)：真实 MAC+PHY，覆盖 RTS/DATA、旁听时序、寄存器读写边界及连续读；无应答时两包应各尝试 7 次并排空。
- [TestDeadlockBackpressure.bsv](../test/TestDeadlockBackpressure.bsv)：MAC 消费暂停、CSMA 完成保持/取消/重启、PHY 忙时排队及信道背压、连续弱 RX、旧控制帧完成与新 RTS 的归属。
- [TestDeadlockP2P.bsv](../test/TestDeadlockP2P.bsv)：双节点真实 MAC+PHY，MCS0—7 × RTS off/on 共 16 档，每档 3 包；同时要求唯一 DATA 交付和发送方成功 ACK 完成。
- [run_deadlock_tests.py](../test/run_deadlock_tests.py)：隔离构建、冻结源码/表、记录指纹和命令、检查显式 PASS/FAIL、拒绝 BSC G0021；另复用原 collision_v2 的 4 项期望结果。

所有生成物放在已忽略的 `output/` 下。本轮未把日志、波形、JSON、mem 副本、编译缓存或 Verilog 放入待提交源码。仿真未定义 BSIM，使用生产模型 200 cycles/µs；不以 Bluesim 默认 `$time` 直接充当模型微秒。

运行完整套件，必须使用一个尚不存在的结果目录：

```bash
cd /home/gtx/dev/RealEmu
python3 test/run_deadlock_tests.py --output output/deadlock-review-next-run
```

脚本优先从 PATH 找 bsc，否则使用当前工作机的安装路径；其他环境可显式传 `--bsc /path/to/bsc`。每个测试有独立编译目录，结果必须含明确的成功标志；只退出 0 或到达仿真终点不能判通过。原 collision_v2 的验收要求 `pass=4 fail=0`。

复现未修改版本可用：

```bash
python3 test/run_deadlock_tests.py --baseline \
  --output output/deadlock-baseline-next-run \
  --case overlap-data --case overlap-cts \
  --case read-done-at --case read-txend-at \
  --case mac-backpressure --case phy-backpressure
```

`--baseline` 读取 HEAD 中的 src/mem，lib 使用工作区子模块；本批核验子模块没有修改。**该基线模式在尚未提交修复时指向旧代码；修复提交后 HEAD 会改变，应先检出指定基线再使用。** 基线故障用例预期退出失败，不能把它们计入修复版 PASS。

## 3. 原版对照

本批使用同一类外部输入重新跑旧 HEAD，不修改被测模块内部状态。为完整排空而使用两包，旧现场的 FIFO10 对应本夹具 FIFO2，根因和状态路径相同。

| 旧版用例 | 观测结果 | 判断 |
| --- | --- | --- |
| 无应答 RTS 基线 | 14 个信道事件、14 次开始/结束，队列归零 | 正常有限重试基线 |
| 旁听 DATA 与本机发送交错 | 信道1、本地开始/结束0，DCF2、FIFO2 | 复现 D01 |
| 旁听中心给另一节点的 CTS | 信道1、本地开始/结束0，DCF2、FIFO2 | 复现隐藏节点相关 D01 |
| done 边界普通读 | 信道0，DCF1、FIFO2 | 复现 D03 |
| txEnd 边界普通读 | 信道1、开始/结束1，DCF2、FIFO2 | 复现 D02 |
| done/txEnd 边界同值写 SLOT=9 | 分别停在 DCF1/DCF2 | 配置写同样能抢掉旧事件，非参数变化导致 |
| MAC 下游暂停后恢复 | 3 个 DATA 已交付，仅发出 2 个 ACK，DCF1 | 复现背压丢 done |
| PHY 接收忙及信道背压 | 4 个请求被接受并转出，仅一次本地 TX 开始/结束 | 复现多请求启动丢失 |
| CSMA 完成保持/取消/重启 | 完成保持等断言失败 | 旧 done 只存在一拍 |

旧版记录：[基线批次](/home/gtx/dev/RealEmu/output/deadlock-fix-20261025-baseline/summary.json)、[基线写操作](/home/gtx/dev/RealEmu/output/deadlock-fix-20261025-baseline-writes/summary.json)。基线普通 txEnd 读在旧批次名称为 read-txend-after，其实际提交周期为39221、处理周期39222，恰好覆盖 txEnd；正式脚本已将边界命名校正。

## 4. 修复版验证

**最终结果：24/24 自动化用例通过；其中 P2P 包含16个 MCS/RTS 子场景，48包全部唯一交付且收到48次ACK完成。** 已校验每个批次的冻结源码、测试源和当前工作区一致。

最终结果以以下三个批次的 summary.json 为准；这些批次使用相同的最终生产源码指纹：

| 批次 | 内容 | 用例数 |
| --- | --- | --- |
| [主功能与背压](/home/gtx/dev/RealEmu/output/deadlock-fix-20261025-completed-main/summary.json) | RTS/DATA、旁听前/同/后拍及中心 CTS、MAC 背压、RTS/DATA 完成归属、双节点交换 | 11 |
| [寄存器读写](/home/gtx/dev/RealEmu/output/deadlock-fix-20261025-completed-registers/summary.json) | done/txEnd 前同后拍读、跨越发送完成的连续读、两个边界同值写 | 9 |
| [退避与 PHY 回归](/home/gtx/dev/RealEmu/output/deadlock-fix-20261025-completed-phy/summary.json) | CSMA 保持/取消/重启、PHY 背压、连续弱帧、collision_v2 四项期望 | 4 |

验收不仅看总吞吐，而是检查以下事件约束：

1. 无应答的两包各发初次+6次重试，最终 14 次发送、14 次结束，DCF/FIFO/PHY/CCA 都恢复空闲。
2. 背压解除后 4 个 PHY 请求按 FIFO 顺序全部发出，各自只有一次开始/结束，txEnd 总高电平周期数也是 4。
3. CSMA 在下游 FIFO 满时保持 done，确认后清除；取消和下一次启动均正常。
4. 连续普通读覆盖 txEnd 后，第一次重试只需等待剩余竞争过程，不再补等一整个被暂停的应答 timeout。
5. 三个控制 ACK 先于本机 RTS/DATA 完成；在真实 MAC+PHY 重放中，使用只读 Bluesim Tcl 检查第一个 RTS/DATA 的计时器：其 TX_END 之前为0，捕获后为1。DATA 另用 timeout=1 µs 的无应答场景检查七次尝试均真正发送，不能用旧 ACK 的计时跳过第一次 DATA。探针不写状态，不参与主功能仿真的输入。
6. MCS0—7 × RTS off/on 的 48 个 DATA 唯一交付，发送方收到 48 次 ACK 完成。

短 timeout 用例还在仅有待发计数、没有应答等待标志的隔离版本上反向验证：它只有9次实际发送（3个ACK和6个DATA），暴露首次 DATA 被旧计时跳过；最终实现要求10次实际发送（3+7）。因此 responseWaitReg 有独立的功能必要性。该隔离对照见 [计时武装对照](/home/gtx/dev/RealEmu/output/deadlock-fix-20261025-counter-only-check/summary.json)，它不是原远端基线。

早期 pilot/final/verified/accepted 名称的实验目录保留了调度问题和中间方案，不作为最终源码通过证据；最终验收使用 `completed-*` 批次。最终汇总和完整性检查见 [验收汇总](/home/gtx/dev/RealEmu/output/deadlock-fix-20261025-acceptance.json)。

## 5. 生产顶层检查与边界

对最终源码重新生成 16 节点 `mkRawEmuCore` Verilog，结果见 [构建记录](/home/gtx/dev/RealEmu/output/deadlock-fix-20261025-completed-production/manifest.json)。编译成功、顶层存在，且没有“规则永远不能执行”的 G0021。已有 G0009/G0010 调度警告仍保留，不能写成零警告通过；实际 schedule 中16个独立 timer 和16个 DONE 保持规则均无阻塞规则，见 [关键调度检查](/home/gtx/dev/RealEmu/output/deadlock-fix-20261025-completed-production/critical-schedule.json)。

本次 Verilog 只用于生产入口编译验收，保存在忽略目录。没有创建或运行新 Vivado 实现，没有重刷板卡。因此，本次证明的是所覆盖条件下 D01—D03 的逻辑活性和正常交换；250/200 MHz 时基、实现负 slack、配置传播、NAV/CW、PHY 干扰尾部、上层完成语义仍按后续报告处理，不能据此宣布板上隐藏节点已与 ns-3 一致。
