**B01 / B02 实现与验证记录**

日期：2026-10-22。修改基于 `c99fa3b`，工作目录 `/home/gtx/dev/RealEmu`。本轮范围是配置传递、统一时基及相应 Bluespec 回归。

**本轮验收结果（2026-10-22 22:30）**

| 检查 | 结果 | 证据 |
|---|---|---|
| MAC 配置行为与边界 | 通过 | [配置测试日志](/home/gtx/dev/RealEmu/test/build/b01-b02-boundary-20261022/config/simulation.log) |
| 微秒、slot、PHY 发帧计时 | 通过 | [时基测试日志](/home/gtx/dev/RealEmu/test/build/b01-b02-boundary-20261022/timebase/simulation.log) |
| PHY 碰撞 v2 | 4/4 用例通过 | [碰撞测试日志](/home/gtx/dev/RealEmu/test/build/b01-b02-regression-20261022/collision/simulation.log) |
| 16 节点真实顶层，MCS7，RTS off/on | 两档均完成；每档突发 2/2，单包延时 1/1 | [顶层短回归日志](/home/gtx/dev/RealEmu/test/build/b01-b02-regression-20261022/p2p-smoke/simulation.log) |
| Verilog 生成及配置/时基检查 | 通过；16 节点、48 条子模块配置写使能 | [RTL 检查日志](/home/gtx/dev/RealEmu/backend/build/b01-b02-20261022/rtl-check.log) |

机器可读汇总：[b01-b02-validation.json](/home/gtx/dev/RealEmu/test/build/b01-b02-regression-20261022/b01-b02-validation.json)。修改涉及的旧 PHY、旧碰撞、Bianchi、完整 P2P 测试台也已通过编译检查。

后续核实（2026-10-23）：完整 P2P 16 组与隐藏节点 8 档统计均在3600秒墙钟上限超时，**未通过完整验收**。上述快速用例结果保持有效。最终历史结果见 [results.json](/home/gtx/dev/RealEmu/test/build/b01-b02-regression-20261022/results.json)；本轮 B03–B08 的新测试、源码和结果另见 [B03–B08 验证记录](/home/gtx/dev/RealEmu/doc/bluespec-b03-b08-results.md)。

**B01 的实现**

`mkMacDCF.handleMacRegAccess` 先构造完整候选配置并校验，成功时在同一个规则执行周期内更新顶层 MAC、CSMA、随机退避生成器和 NAV。写响应返回时，这些消费者已经统一应用配置。原有配置寄存器地址不变。

配置写入等待 MAC/PHY 空闲、发送和接收工作队列排空、NAV 结束后执行。软件应停止注入、等待已有交换结束，再写配置，并等待写响应后恢复注入。连续业务可能持续推迟写响应；同一寄存器请求队列中，后续读请求也会被队首待生效的写请求阻塞。没有队首写请求时，可以在业务期间读取状态。

收到 RTS、发出 CTS 后，原状态机会保留 `NT_RECV_DATA`。如果对端没有发送 DATA，本次实现要求再经过一个配置的 timeout 静默窗口，才允许更新配置，避免中途改参或无限等待。

| 配置字段 | 实际消费者 |
|---|---|
| slot | slot 发生器、NAV |
| SIFS | CSMA 的 SIFS、顶层 Duration 计算、NAV |
| DIFS、EIFS | CSMA 的 IFS 等待 |
| sigTime、ofdmSymbolTime、maxNum、phyDelayTime | 当前 NAV 最小预约时长公式 |
| CWmin、CWmax | 随机退避生成器 |
| timeout、retryLimit、rtsThreshold | 顶层 DCF 状态机 |
| navEn | 顶层旁听帧的 NAV 更新开关 |
| txopEn、filterEn | 保留配置字段；现有协议路径尚无对应行为实现 |

校验包括：slot 非零；CW 指数 0～10 且 CWmin≤CWmax；时间/长度字段不超过 16 bit；retryLimit 不超过 4 bit；布尔字段只能为 0 或 1；拒绝写只读状态。错误写入不改变任何配置，也不增加配置版本号。调整 CW 范围时，跨越当前范围需要先扩大允许范围，再修改另一端点。

CW 范围改变时只重置一次当前指数，并清空旧配置下预生成的随机退避值。其他配置写入不重置 CW，也没有持续同步配置的规则去干扰协议重试。协议中 `resetCW/incrCW` 引起的旧样本问题及增窗上限问题仍归 B05。

新增只读寄存器均位于每节点 MAC 区域，完整地址为 `0x00100000 + node*0x400 + offset`：

| offset | 含义 |
|---|---|
| 0x050 | 已成功应用的配置写次数，32 bit，复位为 0，溢出回绕 |
| 0x054 | 每协议微秒的核时钟周期数，当前为 250 |
| 0x058 | 随机退避生成器当前实际 CW 指数 |
| 0x05C | 当前 NAV 剩余微秒数 |

原 0x040 也改为读取实际 CSMA 状态，避免返回未更新的状态副本。

**B02 的实现**

`Types.bsv` 中 `US_CYCLES=250` 是唯一的 MAC/PHY 时基来源。MAC 的微秒发生器、PHY 的同步/帧时长/采样计时，以及涉及微秒换算的现有测试台均读取这个定义。取消 MAC/PHY 受 `BSIM` 影响而变为 1 cycle/µs 的分支，防止小于固定计算流水线延迟。

Bluesim 的默认 `$time` 仍是仿真器时间，不能直接当作 FPGA 上的纳秒。协议时间使用 `cycleCount / US_CYCLES`；当前 FPGA 核时钟目标为 250 MHz，1 个实际核周期为 4 ns。

slot 修改会重新开始 slot 计数，修复从较大 slot 改成较小值时计数器越过目标、等待 16 bit 回绕的问题。这里不改变 B05 中尚待修复的退避冻结/恢复协议。

当前 250 周期的微秒计数器使用 16 bit，周期内计数范围 0～249；slot 使用 16 bit 微秒计数，零值已被配置校验拒绝。PHY 帧计时使用 32 bit 周期计数，16 bit 长度上限在最低 OFDM 速率下约需 2,185 万周期，仍在表示范围内。

**测试入口与判定方式**

```bash
export PATH=/home/gtx/env/bsc-2025.01.1-ubuntu-22.04/bin:$PATH
cd /home/gtx/dev/RealEmu
python3 scripts/test_bluespec.py
```

默认运行 config、timebase、collision、p2p-smoke 四组。P2P 短回归复用原测试的 DUT、AXI 配置和控制器，在 MCS7 下分别验证 RTS off/on，每档 2 个突发包加 1 次单包延时测量。完整 P2P 仍保留 MCS0～7 × RTS off/on、每档 10 个突发包和 5 次延时测量。

完整统计回归较慢，可以显式运行并留足墙钟时间：

```bash
python3 scripts/test_bluespec.py --tests config timebase collision p2p hidden --timeout 7200
```

每次运行创建独立目录，保存编译日志、仿真日志、精确命令和 `results.json`。判定同时检查进程退出码、失败标记和完成标记；P2P 还检查所选模式的所有 case 和收包数，隐藏节点检查全部 8 档完成且有接收。隐藏节点和 Bianchi 测试的文件日志改为运行目录内的相对路径，避免覆盖历史实验。旧版碰撞测试台也补齐了原先缺失的 AXI-Lite 空闲驱动，恢复其编译，并改用运行目录内日志。

构建启用 `-check-assert`，并将 `G0021`（规则永远无法执行）视为错误。新增配置/时间测试的最终构建没有编译警告；原 PER 文件存在未填满地址区间的加载提示，P2P/隐藏节点会按原测试流程灌满全通过表。

**验证范围**

配置测试覆盖实际 MAC 寄存器入口，包含 DIFS 34/70 µs、SIFS 16/30 µs、CW 范围应用、配置变更清除旧样本、重试增窗不被持续重置、NAV 配置传递、非法写拒绝、配置版本号、交换期间延迟生效、CTS 后 DATA 缺失时恢复配置。

时基测试检查连续 1 µs 脉冲、9 µs slot、slot 从 9 降至 3 µs 的计数重启，以及真实 PHY 的 1038 字节 MCS7 发帧周期。测得该帧 44,014 周期，即 176 µs 对应的 44,000 周期，加现有流水线的 14 周期。SIFS/DIFS 仍使用自由运行微秒脉冲，测量存在不足 1 µs 的相位差；本轮没有宣称已完成 B05/B07 的精确交换边界修复。

Verilog 输出位于 `backend/build/b01-b02-20261022/`。已检查全部 16 个节点的三个子模块配置写使能均连接到实际寄存器写规则，且全部微秒计数器的终值为 249。此次未执行 Vivado 布局布线和上板测试，因此不代表 250 MHz 时序收敛或板载固件已更新。

B03～B07 的帧时长策略、Duration/NAV 语义、CW 饱和及协议更新后的旧随机数、重叠干扰持续时间、响应超时问题仍需后续修复。当前隐藏节点测试每节点每毫秒注入一包，还有序号 0 的去重问题；其结果用于功能回归，不作为与 ns-3 饱和吞吐一致的证明。
