# 隐藏节点改动审查与全量 CSV 归档

审查分支：`hidden-node-16node-20261026-wcl-sim`。基线提交：`e0f302f3beef91aad70dd332ee3b0c28337e9995`。重点检查当前MAC/PHY、仲裁时间线、测试采集/续跑和最后一次完整1～15发送者实验的数据。

结论：发现三个待修复问题，其中一个影响整包最大干扰的判决边界，一个影响已有NAV预约时的CTS响应，一个影响续跑时结果指标的可靠性。此次归档保留测量时的生产代码和数据；没有把旧结果表述成这些问题修复后的结果。

## R1 / P1：仲裁中迟到的包尾干扰漏过最终判决

位置：`src/PhyCore.bsv:516`的RX完成条件、`:774`附近的入站计数，以及 `src/Arbitration.bsv` 的多级传递。

`energyPending`只记录已经进入本PHY接口的事件。当前包的计时按原始空口起点结束，因此干扰虽在目标包结束前开始，但其元数据仍在仲裁/广播队列中时，`energyPending`可以为0。接收端先采用旧峰值上报成功，之后才看到这个干扰；届时已不能撤回成功事件。

新增 `test/TestArbiterTailInterference.bsv` 经生产Arbiter广播到PHY，使用当前PER表在本场景的0/FFFF端点，分别测试目标包尾前100周期、尾前1周期和恰在包尾开始的同功率干扰。预期只有第三个目标包成功，实际第二、第三个均成功：

```text
TAIL_RECEIVED cookie=1 cycle=171001
TAIL_META cookie=33 air=170999 delivered=171003
TEST_FAIL arbiter_tail_interference received=110 expected=100
```

该目标包区间结束于171000，干扰从170999开始，却到171003才进入PHY；171001已上报目标包。尾前100周期的对照能够正确失败，恰在包尾开始的对照正确成功，说明失败点是传递延迟边界。

复现：

```bash
python3 test/run_hidden_node_tests.py --case arbiter-tail-interference \
  --output output/review-tail-replay --timeout 300
```

当前结果为FAIL。此次证据目录：`output/review-20261027-arbiter-tail2/`。测试直接注入仲裁输入，尚未增加真实发送PHY到仲裁的额外传递延迟。

相同问题在全量统计实际使用的50 cycles/µs下也已复现：目标包结束于35000，35001上报成功，起点34999的干扰直到35003才进入PHY。复现参数为 `--case arbiter-tail-interference-fast`，证据目录为 `output/review-20261027-arbiter-tail50/`。两种时基均为`received=110 expected=100`。

建议：在成功提交前确认信道中不再有起点早于本包结束的未处理事件。可采用明确的元数据完成边界；若采用固定完成余量，必须先给出并验证含背压的最大元数据延迟。等待处理完成不能改变原始空口区间，也不能简单把包尾之后的干扰算入本包。现有直接向PHY注入的末周期测试不足以覆盖此边界。

## R2 / P2：SIFS绕过NAV使CTS在已有预约期间发送

位置：`src/MacCore.bsv:233`及`:265`的SIFS旁路，和`:574`的RTS接收分支。

即时应答开始后不重新竞争CCA，与是否允许响应这次RTS，是两个不同的条件。当前代码收到发给自己的RTS就安排CTS，随后SIFS路径同时绕过CCA和NAV，因而即使NAV已被他人的交换预约，也会发CTS，可能破坏已有预约。

本机ns-3 `FrameExchangeManager::ReceiveMpdu` 在安排CTS前检查 `VirtualCsMediumIdle()`，NAV非空时不安排CTS。不能把ACK无需重新竞争的行为直接推广为RTS响应也无需NAV准入。

新增 `test/TestCtsNavReservation.bsv` 先旁听Duration=600µs的CTS，再于100µs收到发给本机的RTS；800µs在预约过期后再发送一次正常RTS作正对照：

```text
当前代码：CTS_NAV_RESPONSE cycle=42006   # 约168.024µs，仍在预约内
当前代码：TEST_FAIL cts_nav_reservation early=1 late=1 expected=0,1
修改前HEAD：TEST_PASS cts_nav_reservation early=0 late=1
```

基线PASS仅说明它没有在本例的NAV有效期内发CTS。旧版本会把第一个CTS延迟至约660µs，仍不等于完整实现了ns-3的丢弃该次RTS响应语义。

复现：

```bash
python3 test/run_hidden_node_tests.py --case cts-nav-reservation \
  --output output/review-nav-replay --timeout 300
python3 test/run_hidden_node_tests.py --case cts-nav-reservation --baseline \
  --output output/review-nav-baseline --timeout 300
```

此次当前版本证据：`output/review-20261027-cts-nav-final/`；基线证据：`output/review-20261027-cts-nav-baseline/`。

建议：保留已获准即时应答的SIFS行为，在接收RTS、决定安排CTS前检查已有NAV。固定RSS星形吞吐测试的中心没有旁听其他节点间的CTS预约，所以该场景的90次PASS不覆盖此问题。

## R3 / P2：续跑重新解析日志后仍信任旧检查点指标

位置：`test/compare_hidden_ns3.py:185`。

续跑调用 `parse_real/parse_reference` 读取原始日志，但丢弃返回值，随后仍把旧JSON里的record放入结果。这样只检查了日志是否具备完成标记，没有确认JSON中的 `unique/mbps/submitted_packets` 等指标与日志相符。检查点指标不一致，或采集程序的指标计算修订后续跑，可能混用旧指标。

在独立的 `output/review-20261027-resume-cache/` 副本中，只将N=1/off的两个检查点 `mbps` 改成999，保留原日志里的292/294个唯一包，`--resume`正常结束并输出Real中位数999Mbps。正确中位数应为23.36Mbps。此探针没有修改最终全量结果目录或归档CSV。

建议：续跑以重新解析的record重建数值字段，仅保留来源和机器耗时等必要元信息；或者显式逐字段比对，不一致时拒绝恢复。原始日志与检查点可再建立校验关联。

## 已纳入仓库改动的结果

[CSV快照及说明](results/hidden-node-1to15-20261027/README.md)保存四份小文件：15行Real汇总、90条Real逐次记录、30行对照汇总和390条完整记录。数据中30次Real/100次ns-3为核验后保留的旧五档，60次Real/200次ns-3为补测；不是390次全部重新运行。

归档完成的检查：

- 检查1～15、RTS开关及每条件3/10个种子的覆盖，390个运行键无重复。
- 逐条重算 `mbps = unique × 0.08`，核对100ms窗口及全部Real排空标记。
- 从逐次记录重新计算15行Real汇总和30行对照中的中位数、范围与相对误差，均匹配。
- 两份汇总CSV逐字节复制；两份逐次CSV仅把 `reused_from` 绝对路径转为仓库相对路径，保留全部指标。
- `manifest.json`记录来源、生产源码/ROM、模型、参考程序、库和归档文件校验值。
- 快照不依赖被忽略的运行元数据即可重画曲线，绘图输出仍可放在 `output/`；重绘的两张PNG与原始最终图片逐像素一致。

构建、日志、图片仍由原规则忽略；没有放开整个 `output/`，也没有加入生成的Verilog。原48次回归和90次吞吐/排空PASS是既有范围的实际结果；本次新增的两个集成边界测试均FAIL，不能据此继续宣称所有边界都已通过。

本次三个失败配置是包尾干扰250/50两种时基，以及CTS/NAV当前版本；它们的编译与链接均成功，框架依据`TEST_FAIL`判定失败。CTS/NAV的修改前基线对照为PASS。续跑检查在独立副本中复现指标不一致被接受，原全量数据和CSV归档没有修改成探针数值。

物理实现仍需对新的功率聚合路径完成250MHz Vivado时序验收；50 cycles/µs的统计仿真和默认时基的短窗口校验不能替代该项。
