# T01/T02、C01/C02：时基、PHY 流水和配置可靠性实施记录

本轮承接 D01—D03 死锁修复。分支为 `hidden-node-16node-20261024-wcl`，提交基线为 `1203808a7a0369772aaae87d53ae71e80b2d57b8`，改动尚未提交。实施前的 D 补丁工作树保存在 `output/tc-fix-20261026-before/`；本报告中的“修改前”指这份工作树，而不是不含 D 修复的 HEAD。

实现保留原有 MAC/PHY 状态机、节点接口、分组仲裁和 DMA 包布局。生产修改集中于原有计时流水、配置 put 接口和容易丢失单拍 valid 的桥接边界。PHY 继续采用 mode0 的整包 PRR 与碰撞标记决定最终收包，没有增加分段 BER 模型。

## 1. T01：统一实际时基

| 文件 | 改动 | 原因和作用 |
| --- | --- | --- |
| `src/Types.bsv` | `REALEMU_US_CYCLES` 默认 250，`US_CYCLES` 从它派生；支持编译参数显式覆盖 | XDMA 给核心的 `user_clk` 为 250 MHz，原 200 会让时间整体缩短至 0.8 倍 |
| `src/MacCore.bsv` | 微秒发生器使用 `valueOf(US_CYCLES)` | slot、SIFS、DIFS、timeout 等以同一模型微秒工作 |
| `src/PhyCore.bsv` | PHY 使用同一常量，取消 MAC/PHY 内 BSIM=1 的特殊计时 | 避免 MAC/PHY 不同速度以及短于查表流水的“微秒” |
| `test/TestP2P.bsv`、`TestPhy.bsv`、`TestBsvTop_{hidden_v2,bianchi,collision,collision_v2}.bsv` | 将相应调度/吞吐/延迟中的 200 换算改为公共时基 | 改频率后测试仍保持原有模型时长；不据此宣称旧统计测试已全部修好 |

当前一个模型微秒为 250 周期，一个硬件周期为 4 ns。Bluesim 默认时钟则为 10 个仿真时间单位/周期；历史日志中的 `$time`、`ns` 后缀不能直接解释成模型空口时间。验收按周期数除以 `US_CYCLES` 计算。

## 2. T02：时长结果归属、延迟补偿与关键路径

修改集中在 `src/PhyCore.bsv`：

1. TX/RX 分别用小 FIFO 提交时长请求，共用原除法器。每次请求携带 TX/RX 类型、开始/到达周期、RX 强弱标记；TX 与 RX 同拍到达时两者均保留。接收入口同时保存到达周期，排队不会把整段能量占用重新起算。
2. 除法标签与响应同步消费，商位宽从 10 增到 18，覆盖 16-bit 帧长。以独立寄存级隔开“符号数 → 乘 `4*C` → 加前导 → timer/CCA”，切断旧的除法响应直接进入 CCA 算术路径。
3. 计时装载时扣除从原始事件到结果返回的流水延迟。TX/RX 的 epoch 必须匹配，旧结果不能装载新帧 timer；强 RX 即使时长仍在计算，也先覆盖前导期 CCA。
4. RX 的整帧剩余时间贯穿 SYNC/RX，前导计时也扣除已过的到达时间。TX 等待自己的时长结果；不会拿上次 timer 过早结束。周期时间戳用模 2^32 差值处理本次事件的短间隔。
5. 原先“恰好剩 30 周期才发起查表”改为每个接收阶段最多提交一次、提前至剩余不大于 128 周期的查表。请求标签带帧 epoch、阶段、MCS、功率，穿过二分搜索和 PER BRAM；响应保留到对应物理阶段结束。
6. 成功 RX 向已有 MAC 接收 FIFO 的入队与帧完成原子执行。下游暂满时保留待交付结果，避免完成脉冲经过单拍 CRC 标记后丢失。

固定流水不会被当成额外空口时间。极端队列背压仍可能让处理晚于物理截止点，但结果会保留、按原截止点补偿；这不等于模拟了任意密度输入下所有无线物理现象。

## 3. C01：配置进入实际消费者

`src/MacCore.bsv` 的寄存器处理先构造本次写入后的完整 `nextCfg`，然后在同一动作中更新顶层并调用原有 `backOffFsm.putmaccfg`。退避模块将同一快照传给随机窗口和 NAV，修复“读回已变、实际仍用默认值”。

变更配置要求节点空闲：DCF_IDLE、无待完成 TX、相关发送队列空、退避可用、PHY_IDLE。忙时改变值返回现有错误响应，由 AXI-Lite 映射为 SLVERR；同值重写可以成功，不重复重置退避。驱动应停止发流并排空后配置，不能把这一机制理解为跨多个寄存器的事务提交。

校验拒绝 slot=0、CW 指数大于 10、CWmin>CWmax 及截断会丢位的值。CW 字段仍是指数，例如 4 表示 15，10 表示 1023；扩大 CWmin 时先调整 CWmax，缩小 CWmax 时先调整 CWmin。

`src/CsmaUtils.bsv` 在配置应用时重置当前 CW 到新 CWmin，清掉旧配置的预取随机样本；`incrCW` 在等于 CWmax 时也饱和。slot 改变时重置 slot 相位，防止缩短 slot 后计数越过比较点并等待回绕。普通重试 `incr/reset` 的预取样本语义及冻结恢复仍属于 M01 的后续范围。

本次 NAV 验证证明相关参数能到达现有 NAV 计算器，不代表 Duration/NAV 算法已与 ns-3 等价。SIG_TIME 等 MAC 配置也不会自动改写 PHY 的 802.11a 空口常量。

首次布局后确认新的最差路径是 NAV 的配置乘加/比较：`macCfg → DSP → newNavReg`，13 级逻辑、4.248ns 数据延迟、WNS=-0.346ns。因此增加一个 16-bit `navSymbolBudget`，在原配置 put 动作中同步缓存 `ofdmSymbolTime * maxNum`，收帧路径只使用缓存乘积。保持原有 16-bit 运算、NAV 公式和接收事件时序，没有增加接收状态或配置事务。补充定向测试将 symbol=7、maxNum=40，实际 NAV 下限为 538µs；缓存后的完整 10 个 T/C 用例和 24 个死锁/协议回归均已通过。

## 4. C02：背压下保留事件与配置完成边界

| 文件 | 改动 | 作用 |
| --- | --- | --- |
| `src/BsvTov_simple.bsv` | 按 tag 只入真实目标队列，目标入队与入口 deq 原子执行 | MAC/config/PER 某一路满时不再先取走再漏投 |
| `src/MacBridge.bsv` | 保留分组选择；选择寄存器保持到消费；上传和下传的瞬时数据改为 FIFO | 分组仲裁或主机/节点暂停后，事件仍能恢复交付 |
| `src/Arbitration.bsv` | 保留分组选择；全局广播事件留在 FIFO，所有非源节点同时可接受时才推进 | 某一节点满不会让其他节点收到后重复广播，也不会漏掉被阻塞节点 |
| `src/CfgBridge.bsv` | 两级配置流水改为 FIFO；距离写等待目标响应；PER 原子广播并收齐 16 位完成掩码 | 入口接受不再冒充所有消费者完成 |
| `src/Channel.bsv`、`src/PhyCore.bsv` | BRAM 写启用 `responseOnWrite=True`，消费写响应之后回 GenericResp | 配置完成与实际 BRAM 写完成对应 |
| `src/BsvTov_simple.bsv` | 路由配置时累计 `cfgPending`，完成响应回来后减少；DATA 必须等待为 0 | 同一 DMA 输入流中，连续配置后的 DATA 自动等待这些配置生效 |

应区分三个边界：

1. 主机 DMA write 返回：数据进入传输/入口，**不是 BRAM 已完成**。
2. 内部 GenericResp：距离的目标 BRAM 已完成；PER 的 16 个节点均已完成。
3. 同一输入流的后续 DATA 放行：排在它之前、已路由的配置均完成。这是本次提供的内部顺序屏障。

该屏障不排空先前已经发出的无线帧，也不为 AXI-Lite 与 DMA 两个独立通道建立全局顺序；实验开始前仍应停止发流配置。本次没有添加主机可查询的完成计数接口。有限背压解除后要求事件守恒；下游永久不消费时，允许系统持续反压。

有效距离配置要求源/目的节点在 0—15。原 GenericResp 没有错误字段，无效目的节点完成但不写入，未扩展主机错误协议；未定义 tag 不进入完成计数。部分写 WSTRB、无效 AXI 地址的完整协议验收及主机完成查询仍归 C03，不在本次完成声明内。

## 5. 自动化仿真与证据

入口为 `test/run_tc_tests.py` 和 `test/run_deadlock_tests.py`，每次指定独立 `output/` 目录。运行器冻结设计/库/ROM/初始化脚本，逐用例记录宏、测试 SHA256、命令、退出码和明确 PASS 标记；编译返回 0 但出现 G0021 也算失败。完整核心会生成并加载实际 `bram_one.txt`。有限背压测试检查完整 ID 集合及次数。

全部最终 T/C 结果在 `output/tc-fix-20261026-final-tc/`；该目录的 `manifest.json` 与第二轮 Vivado 源码完全对应。

| 用例 | 检查内容 | 结果 |
| --- | --- | --- |
| clock-250 / clock-200 | 微秒 tick 恰好 C 周期；slot 9→2 的相位；200 为显式编译覆盖 | 两项通过 |
| mac-config | 公共寄存器写后的实际 SIFS=3、DIFS=3/CW=0、NAV 下限538µs；非法值及忙时写拒绝 | 通过 |
| cw-config | 配置前有预取样本，新 CW0 的首样本即为 0；CW1→CW3 并在 max 饱和；CW1023→CW0 | 通过 |
| phy-timing | 11 组独立预计算 TX 时长；排队 RX、TX 中弱 RX、同拍短 TX/长强 RX 的 CCA | 通过 |
| mac-bridge | 下行 50、上行 64 个唯一事件；暂停/恢复下游 | 通过 |
| arbiter | 64 个事件各广播到 15 节点，共 960 份；节点 15 背压 | 通过 |
| cfg-bridge | 16 个距离目标及 3 次 PER×16 节点；节点 15 延迟响应，禁止提前完成 | 通过 |
| config-fence | 真实 16 节点核心，AXI-Lite 配置节点 0/3/4/15；距离 16 与连续 32 条 PER 更新后立即 DATA | 通过 |
| p2p | MCS0—7 × RTS关/开，共 16 档、48 个 DATA 和 ACK 完成 | 通过 |

`phy-timing` 的部分独立预期：1500B@6Mbps=2024µs；1062B 的 MCS0—7 为 1440/968/732/496/376/260/200/180µs；65535B@54Mbps=9732µs；14B@54Mbps=24µs。TX 持续周期与预期完全一致；RX 观察点有一次接口交付周期差。

完整核心距离 16 的 ROM 损耗为 771，输入功率 1000，测试断言实际接收功率为 **229**，区别于默认距离 8。配置写入的 PER 地址覆盖该接收功率对应的查表项，强制成功用于验证配置传播，不把随机收包当成配置正确的证据。

| 节点 | 配置 SIFS（µs） | 实际 DATA 收到到 ACK 提交（周期） | 模型 µs |
| --- | --- | --- | --- |
| 0 | 4 | 982 | 3.928 |
| 3 | 7 | 1732 | 6.928 |
| 4 | 8 | 1982 | 7.928 |
| 15 | 19 | 4732 | 18.928 |

差值来自微秒 tick 相位及 MAC 观察点，不超过一个模型微秒。只读重放探针在第一条 DATA 入流后 16 周期看到 `cfgPending=8`、发送 MAC 输入计数为 0；第一条 DATA 实际提交发送时 `cfgPending=0`，证明 DATA 没有越过仍未完成的配置。

此前试跑目录保留定位过程：曾修正 phy-timing 的测试语法和距离16的测试期望值（按现有ROM量化值为229，不能近似为230）。这些历史试跑均不计入最终通过数，最终结果统一采用 `final-tc` 与 `final-deadlock`。

### 5.1 原死锁回归及修改前对照

250 cycles/µs、NAV 缓存后的最终 D01—D03、P2P 与碰撞回归保存在 `output/tc-fix-20261026-final-deadlock/`。寄存器边界探针按本次参考仿真的实际发送/完成周期生成，避免改时钟后探针已偏离原本要检查的同拍边界。

最终 **10/10 个 T/C 用例通过、24/24 个原有回归通过**，二者共用 P2P，是 33 个不同用例。这些结果包含 NAV 缓存修正；设计源码、库、ROM、初始化脚本的 SHA256 与当前工作树一致，Vivado 源码及 RTL 输入也逐项一致。前轮历史结果保留用于追溯，最终采用本节列出的两个 `final-*` 目录。

修改前工作树上的同组 T/C 对照保存在 `output/tc-fix-20261026-baseline/`，7/7 个针对性用例失败：slot 缩短不生效、非法 slot 未拒绝、配置 CW0 后仍输出旧样本 13、RX 时长错误、MAC 桥丢失事件、广播缺失、PER 提前确认。这里 `clock-250` 是用例名称，修改前 manifest 的实际公共时基仍是 200；该项直接检测的是 slot 相位。

汇总与源码一致性记录为 `output/tc-fix-20261026-acceptance.json`。BSC 仍有 G0009/G0010 调度提示，本轮选用结果没有 G0021；未把“无任何告警”作为完成声明。

## 6. 250 MHz Vivado 实现验收

最终模板副本为 `/home/gtx/project/run261026-tc-nav/`，器件 **xcu280-fsvh2892-2L-e**，Vivado **2022.2**。未使用旧文档的 xcvu13p 标注。

最终 RTL 包为 `output/tc-fix-20261026-nav-rtl/rtl/`，来自包含 D/T/C 和 NAV 缓存修正的 16 节点生产顶层，18 个 RTL、3 个 ROM 和 bram_one 共22个文件。副本 `verification/manifest.json` 记录实际实现输入的设计源码及 RTL/ROM SHA256，与当前源码和最终仿真快照逐项一致。

`backend/vivado/validate_timing.tcl`（整理前位于`backend/validate_timing.tcl`）校验 `US_CYCLES=XDMA axisten_freq`，清除模板旧 RTL 注册，装载本次文件，重跑综合、布局布线及布线后物理优化。保持原有板卡/IP 时序约束，验收要求 `user_clk=4ns`、setup/hold 均非负；报告写到该副本 `verification/`。当时使用的脚本副本仍保存在工程`verification/`中；目录整理未覆盖原始验收记录。

模板 XDC 第77—80行仍对不存在的 `free_run_clock_p_in/n_in` 设置管脚和电平标准，产生4条 Common 17-55 严重告警；具体定位见实现日志。它们是模板残留约束，本次没有用改时序例外的方式屏蔽。验收另行检查实际 `user_clk`、完整 routed setup/hold、布线状态和 DRC，不宣称工具输出没有告警。

**实现验收状态：通过。最终布线后物理优化报告明确为 `All user specified timing constraints are met.`，不是采用布局估计值。**

| 检查 | 最终结果 |
| --- | --- |
| 实际核心时钟 | user_clk：4.000ns / 250MHz；模型250 cycles/µs |
| Setup | WNS=+0.002ns，TNS=0，失败端点0 |
| Hold | WHS=+0.009ns，THS=0，失败端点0 |
| Pulse width | TPWS=0，失败端点0 |
| 内部时序覆盖 | no_clock=0，unconstrained_internal_endpoints=0，组合环=0 |
| 布线 | 344419/344419条可布线网络全部完成，routing errors=0；布线后物理优化只调整两条网络，未新增/删除逻辑单元 |
| DRC | Error=0；119条普通告警保留并记录 |

setup裕量只有2ps，验收结论对应这份具体实现；后续改RTL或实现策略应重新验收。本次没有把频率降到200MHz，也没有新增false-path/multicycle例外来绕过PHY路径。

原始最终时序报告为 `xdma_0_ex/xdma_0_ex.runs/impl_1/xilinx_dma_pcie_ep_timing_summary_postroute_physopted.rpt`，检查点为同目录的 `xilinx_dma_pcie_ep_postroute_physopt.dcp`。工程 `verification/` 还保存验收脚本、源码/RTL清单以及最终时序、资源、DRC、布线状态汇总。

验收脚本以退出码0结束，明确输出 `REALEMU_TIMING_PASS setup=0.002 hold=0.009 period=4.000`。简要实现证据另存 `output/tc-fix-20261026-implementation/`；总汇总 `output/tc-fix-20261026-acceptance.json` 中 `overall_passed=true`，含源码、测试脚本和各最终报告SHA256。工程登记的22个包文件也已逐项与清单核对。

全工程（含XDMA）资源为：CLB LUT 208776（16.01%）、CLB寄存器210586（8.08%）、BRAM tile 204（10.12%）、DSP 32（0.35%）。

方法学报告另有XDMA/PCIe IP继承的TIMING-54告警，涉及sys_clk与GT内部时钟的scoped clock group；没有用它排除本次PHY的user_clk数据路径。普通DRC告警包括DSP流水建议、BRAM write-first碰撞提示和一条无可布线负载提示；距离/PER更新期间仍须按第4节停止并排空先前发流。

首轮最差路径定位报告为 `/home/gtx/project/run261026-tc/verification/placed-critical-paths.rpt`。获得定位证据后主动停止首轮旧优化任务，保留其布局检查点；首轮没有 routed 通过结论。第二轮尝试读取该参考，但单元匹配71.60%、网络匹配69.90%，未达到Vivado默认80%/75%门槛，自动回退完整布局；未强制复用。最终仍重新综合、完整布局和实际布线，检查同一4ns约束。上一轮功能记录归档到 `output/tc-fix-20261026-nav-before/pre-cache-acceptance.json`。

## 7. 剩余范围

M01 的普通重试预取/冻结恢复、M02/M03 的 Duration/NAV/应答策略，以及 P01/P02 的干扰尾部和 mode0 概率近似仍需分别验证。本轮没有把隐藏节点吞吐量或 ns-3 全语义一致性宣布为通过。板上仍需在确认固件版本、时钟和 driver 配置后单独验收。
