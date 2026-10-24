**RealEmu 隐藏节点对齐：底层 Bluespec 待办计划**

更新日期：2026-10-24。代码基线：RealEmu `c99fa3b`；以下描述当前工作区相对基线的修改，不代表已经提交。用户已刷新板卡，本文件补充本次实测结果；寄存器ABI不能唯一识别具体bit构建。本文件同时记录完成状态、具体代码修改、修改原因、验证证据和剩余待办。

**当前进度：B01–B08 的实现和本轮功能回归已完成；B09 的模块/短集成回归、生产顶层 Verilog 生成已完成，长统计验收尚未完成。** 最新冻结源码回归为10/10组通过，目录是 `test/build/b03-b08-delivery-20261023/`。详细结果见 [B03–B08 验证记录](/home/gtx/dev/RealEmu/doc/bluespec-b03-b08-results.md) 和 [机器可读验收汇总](/home/gtx/dev/RealEmu/test/build/b03-b08-delivery-20261023/validation.json)。[B01/B02 验证记录](/home/gtx/dev/RealEmu/doc/bluespec-b01-b02-results.md) 保留历史过程，其中旧实现和旧测试入口不能代替本文件的当前状态。

**当前采用的误码模型：继续保留 mode 0。** `PhyCore.bsv` 的 `bitModel` 默认值是 `False`，节点寄存器偏移 `0x26C` 为0时，使用原整包成功率（PRR）表及有效强干扰重叠失败判定。现阶段不切换到按 bit 数加权的 mode 1，也不要求更换为单 bit 概率表。B06 的活跃信号、干扰尾部和边界修复在 mode 0 下同样生效。

mode 1 已有可选实现和定向功能测试，保留为后续研究能力；其概率表标定、精度改进和启用暂缓，不作为当前 mode 0 交付的前置条件。mode 0 仍需要概率统计验收；10/10功能通过不等于隐藏节点吞吐、丢包率已经与 ns-3 对齐，也不等于 Vivado 250MHz 时序通过。

**2026-10-24 板测未通过，优先处理B09-7。** 16节点均读到新版MAC/PHY ABI、250周期/µs及mode0，但连续DMA写入超时，锁存后未更新的3个PHY快照读数仍变化；最小单包提交成功、MAC输入1，却读到DATA尝试20、pending=`0xFFFFFFFB`，主机收包0。原有C工具复现DMA及异常计数，设备级DMA恢复后仍失败。`run261023`已完成实现，但WNS为−10.234ns、253324个setup端点失败。当前不能进行可信隐藏节点统计或宣称板级功能通过；时序违例是首要排查方向，尚未证明全部异常的唯一根因。详见[板测报告](/home/gtx/dev/RealEmu-driver-20261009/tests/board-hidden-20261024/REPORT.md)。本次未修改Bluespec/Verilog，也未重跑10组Bluesim回归。

**精简待办清单**

- [x] B01：打通 MAC → CSMA → 随机退避/NAV 的配置传递，验证实际生效值。
- [x] B02：统一 MAC、PHY、测试台的时基，适配当前 250 MHz 核时钟。
- [x] B03：统一帧时长计算与控制帧速率选择，MAC 预约和 PHY 发射采用公共公式。
- [x] B04：修复 RTS/CTS/DATA Duration、NAV 更新与显式复位。
- [x] B05：按当前 CW 取样，修正饱和增窗、冻结恢复、完整 slot 计时和 SIFS 响应后的退避恢复。
- [x] B06：保留活跃信号至各自结束，修复连续重叠帧的干扰遗漏；当前继续采用 mode 0。
- [x] B07：拆分 CTS/ACK 响应等待阶段，匹配类型、对端及交换编号，修复最终失败完成握手。
- [x] B08：增加有效配置、当前 CW/NAV、响应阶段及 MAC/PHY 诊断计数和快照。
- [ ] B09：10组功能回归和 Verilog 检查已完成；仍需修复长统计台的去重、轮次隔离和负载控制，完成 mode 0 概率与隐藏节点统计验收。

接下来优先完成：①修复实现时序及板级基础收发/诊断异常；②修复统计口径；③验证 mode 0 中间概率值；④固定配置、多seed比较RTS开关及多发送端；⑤同条件ns-3对照。mode 1 标定暂缓。

**执行顺序与涉及文件**

| 编号 | 优先级 | 前置依赖 | 主要修改位置 | 完成后应得到的行为 |
|---|---|---|---|---|
| B01 | P0 | 无 | `MacCore.bsv`、`CsmaUtils.bsv`、`Types.bsv` | 写配置能改变实际退避和 IFS 行为 |
| B02 | P0 | 无 | `Types.bsv`、`MacCore.bsv`、`PhyCore.bsv`、测试台 | 设计中的 1 µs 与真实时钟一致 |
| B03 | P0 | B01、B02 | 已新增 `FrameTiming.bsv`；MAC、PHY、CsmaUtils | 包长、速率、Duration 与空口时间一致 |
| B04 | P0 | B03 | `MacCore.bsv`、控制帧构造接口 | CTS 正确保护 DATA 和 ACK |
| B05 | P0 | B01、B02 | `CsmaUtils.bsv`、`MacCore.bsv` | CW 更新立即生效，冻结后按规则恢复 |
| B06 | P1 | B02、B03 | `PhyCore.bsv`、新增 `ReceptionModel.bsv`、`Types.bsv` | 放弃接收的帧仍产生持续干扰，mode 0 正确保留碰撞历史 |
| B07 | P1 | B03、B04、B05；与 B06 协调 PHY 事件 | `MacCore.bsv`、`PhyCore.bsv`、`Types.bsv` | 响应等待有清晰起止，迟到帧不完成错误交换 |
| B08 | P1 | 跟随 B01～B07 实施 | `Types.bsv`、MAC/PHY 寄存器处理 | 能解释失败原因、核验实际配置 |
| B09 | P0 | 各项模块回归随任务执行；最终依赖 B01～B08 | `test/`、`backend/` | 功能回归通过，生成 RTL 与预期一致 |

P0/P1 保留原计划的优先级，不表示 B01–B08 尚未实施。下面逐项说明已经改动的代码；功能验收以最新冻结源码和日志为准。B06 的 mode 0 语义、可选 mode 1 算法与物理模型标定分别记录。

**B01：修复配置传递。优先级 P0，是调参实验的前置条件。**

基线 `c99fa3b` 的 `mkMacDCF` AXI-Lite 写操作只更新顶层 `macCfgReg`，没有向 `backOffFsm.putmaccfg` 传递。CSMA 的配置方法也没有更新 `navController`。生成 RTL 中对应子模块配置寄存器的写使能固定为 0。因此，软件请求 `CW_MAX=10` 不代表随机退避实际采用 1023 窗口；基线子模块仍保留默认指数 6。本轮已修复这条配置路径。

涉及代码：[MAC 与 CSMA 配置入口](/home/gtx/dev/RealEmu/src/MacCore.bsv:427)、[随机窗口配置](/home/gtx/dev/RealEmu/src/CsmaUtils.bsv:122)、[配置类型](/home/gtx/dev/RealEmu/src/Types.bsv:107)。

| 已修改的代码 | 原因 | 当前作用 |
|---|---|---|
| `mkMacDCF.handleMacRegAccess` 构造、校验 `nextCfg`，同周期更新 `macCfgReg` 并调用 `backOffFsm.putmaccfg.put(nextCfg)` | 原来只改顶层副本，下层仍采用默认值 | 写响应成功后，MAC 与下层消费的是同一份已应用配置 |
| `mkCsmaCaBackOff.putmaccfg` 同步更新自身、`expBackOffGen` 和 `navController` | 配置链在 CSMA/NAV 处断开 | CW、IFS、NAV 开关等能够改变实际行为 |
| `cfgQueuesIdle`、`trackConfigQuiet`、`cfgCanApply` | 交换中途改参会混用不同配置；发 CTS 后未收到 DATA 可能一直等不到生效边界 | 空闲排空后应用配置；CTS 后无 DATA 时经过 timeout 静默窗口恢复配置处理 |
| 写入范围校验和 `cfgGeneration`；读回 `currentCW`、实际 CSMA 状态和 NAV | 顶层回读值不足以证明下层生效 | 非法写入无副作用，成功配置有代次，可用实际状态核验 |

当前校验还覆盖控制 MCS 0–7、非零 timeout 和退避 seed。CW 范围改变时重置当前窗口；其他配置写入不反复重置 CW。诊断快照/清零不要求排空业务，普通配置写入仍遵守空闲生效边界。

已完成的实施项：

- [x] 梳理每个配置字段的消费模块，明确顶层、CSMA、随机窗口、NAV 和 slot 发生器各自读取哪些字段。
- [x] 补齐 `mkMacDCF → backOffFsm → expBackOffGen/navController` 的传递路径。
- [x] 明确配置生效边界。首版采用停止注入、排空已有工作后在空闲边界统一应用配置，用写响应与配置版本号标识完成，再恢复注入。
- [x] 对配置进行范围校验：slot 非零、CWmin 不大于 CWmax、CW 指数不超过实现支持范围。
- [x] 配置应用与协议中的 `resetCW/incrCW` 分开。不得在持续同步配置时反复把当前 CW 重置为 CWmin。
- [x] 提供实际生效配置或配置版本号的读取，不能只回读软件写入的顶层副本。

验收用例：通过 `macRegSrv`/AXI-Lite 配置整颗 MAC，分别改变 CW、SIFS、DIFS，观察实际发包时刻和退避范围变化；确认 timeout、RTS threshold、retry 等原本由顶层消费的字段没有回归。测试不能绕过顶层而直接调用退避子模块的配置接口。

完成证据：配置消费关系表；寄存器写入→生效→行为变化的仿真日志；生成 RTL 中配置写入路径实际存在。

已验证：`TestMacConfigApply.bsv` 从 MAC 寄存器入口检查 DIFS 34/70µs、SIFS 16/30µs、CW/NAV、非法写入和延迟生效；`TestP2P.bsv` 短集成经实际 AXI-Lite 桥完成配置。最新 RTL 中 MAC/退避配置写使能和 NAV 选择逻辑存在。

**B02：统一时间基准。优先级 P0。**

基线工程核时钟为 250 MHz，MAC/PHY 却使用 200 cycles/µs。本轮已统一为 `US_CYCLES=250`；未来更换核时钟时只修改这一来源，并验证构建配置与实际时钟一致。

涉及代码：[US_CYCLES](/home/gtx/dev/RealEmu/src/Types.bsv)、[MAC 微秒发生器](/home/gtx/dev/RealEmu/src/MacCore.bsv)、[PHY 时基](/home/gtx/dev/RealEmu/src/PhyCore.bsv)、[时间发生器](/home/gtx/dev/RealEmu/src/CsmaUtils.bsv)。

| 已修改的代码 | 原因 | 当前作用 |
|---|---|---|
| `Types.bsv: US_CYCLES=250`；MAC/PHY 与相关测试统一引用 | 250MHz 核时钟却按200周期换算1µs，会系统性缩短协议时间 | 1µs 对应250个核周期，slot、超时、统计时间采用同一单位 |
| MAC/PHY 取消 `BSIM` 下改为1周期/µs的分支 | 时间压缩会短于计算流水线，导致仿真与实际逻辑语义不同 | Bluesim 按相同协议周期比例运行；`$time` 不直接充当协议µs |
| `CsmaUtils.mkSlotGen` 检测 slot 变化并重新计数 | 从较大 slot 改为较小值可能错过比较点，等到计数回绕 | 9µs→3µs等配置切换能够立即重建正确周期 |
| `TestPhy`、碰撞、P2P、hidden、Bianchi 等测试中的时间换算 | 设计改时基但测试仍用200会产生假失败或错误统计 | 注入时刻、等待窗口和报告换算随公共定义变化 |

已验证：`TestTimebase.bsv` 检查250周期微秒脉冲、9µs slot及9→3µs重配。叠加B03后的最新PHY发帧结果为1038B/MCS7精确44000周期（176µs），旧B01/B02日志中的额外14周期已不适用于当前版本。寄存器 `0x054` 可读取250。

已完成的实施项：

- [x] 让 `US_CYCLES` 或等价的构建参数成为 MAC、PHY 和测试台的统一来源，当前目标为 250。
- [x] 替换 `mkUsGen(200)`、PHY 的 `clkFreq=200` 以及测试中的 `*200`、`/200` 等散落常量。
- [x] 区分微秒、周期、slot 三种单位；转换集中实现，并检查位宽、溢出和减法下溢。
- [x] 核查 `BSIM` 条件编译。不能简单把时间比例改成 1：现有固定流水线延迟和类似 `timer==30` 的触发点也必须成立。
- [x] 定义仿真的逻辑时间换算。`$time`、cycle 计数和报告中的 µs 必须明确对应，不能混用。
- [x] 提供核心频率/时基参数的只读信息，供后续板测辨认构建版本。

验收用例：单独验证 1 µs 脉冲周期、9 µs slot、16 µs SIFS、34 µs DIFS；验证连续计时及计数边界。PHY airtime 应在定义的帧开始/结束边界满足预期周期数；跨模块固定延迟单独记录，不能用吞吐拟合去调整时基。

完成证据：统一时基定义；周期与微秒对照日志；所有相关测试不再自行硬编码旧换算值。

**B03：建立一致的帧时长和控制速率计算。优先级 P0。**

已新增 [FrameTiming.bsv](/home/gtx/dev/RealEmu/src/FrameTiming.bsv:6)，集中提供计算接口：

```text
NDBPS = {24, 36, 48, 72, 96, 144, 192, 216}
T_PPDU_us(L, MCS) = 20 + 4 × ceil((8×L + 22) / NDBPS[MCS])
```

`L` 明确为含 FCS 的 PSDU 字节数。当前 PHY 已包含 22 bit SERVICE/tail，不能再通过额外补包长重复计算。

| 已修改的代码 | 原因 | 当前作用 |
|---|---|---|
| `ofdmSymbols`、`frameTimeUs`、`symbolsToCycles` | MAC、PHY 原有独立时长和固定控制时长容易不一致；旧符号数位宽不足 | 使用同一 OFDM 公式，符号数为20bit，覆盖16bit包长范围 |
| `MacConfig.controlMcs`、默认值0、寄存器 `0x060`；`dcfWaitBackOff` 设置控制帧 MCS | 预约采用的控制速率必须等于真正发射速率 | 默认6Mbps，可配 MCS0–7；已验证24Mbps控制帧 |
| PHY `prepareReceive`、`prepareTransmit` 及携带帧信息的队列 | 多周期计算不能错用后一帧的长度、速率或身份 | 符号数与原帧、到达周期一起传递；TX计算完成且输出可接收后才开始 |
| PHY `airClock` 的逻辑时刻、`arrivalEnd` 和 TXSTART/TXEND 边界 | 把计算流水线耗时计入空口时长会改变竞争和重叠边界 | 接收按原到达时刻计算结束；发射事件与起点一致，不额外拉长PPDU |

`ofdmSymbols` 使用按MCS选择的常数除数，PHY先寄存符号数再换算周期；这说明代码可生成RTL，不代表250MHz实现时序已经验收。

已完成的实施项：

- [x] 统一 DATA、RTS、CTS、ACK 的长度定义；控制帧 PSDU 长度分别为 20、14、14 字节。
- [x] 将 `CsmaUtils.bsv` 中的固定控制帧时长，替换成依据实际长度和速率得到的结果。
- [x] 把控制帧速率选择集中管理，让 MAC 的 Duration 计算与 PHY 真正发射使用同一个结果。
- [x] 首先保留一个明确的 6 Mbps 控制帧配置用于自身回归，再提供后续对照所需的速率参数；ns-3 实际响应速率尚需外部基准确认。
- [x] 采用可综合的常数除数计算并在PHY寄存符号数；Verilog已生成。250MHz下的布局布线时序留待Vivado验收，未勾选为已通过。
- [x] 多周期结果携带对应帧标签、长度、MCS、功率和到达/发射基准时刻；接收侧补偿计算延迟，避免使用后一帧的元数据。
- [x] 明确计算服务背压：请求不能被悄悄丢弃，计算尚未完成时不能使用默认时长发帧。

验收参考：

| PSDU/速率 | 期望 airtime |
|---|---:|
| RTS 20B @6M | 52 µs |
| CTS/ACK 14B @6M | 44 µs |
| ACK 14B @24M | 28 µs |
| DATA 1038B @54M | 176 µs |
| DATA 1064B @54M | 180 µs |

验收覆盖 MCS0～7、OFDM 符号边界附近包长、连续到达的不同长度/速率帧。逐项确认 MAC 预约计算和 PHY 实际计时一致。

已验证：`TestFrameTiming.bsv` 穷举8种MCS×65536种包长，共524288组公式结果，并检查控制速率、Duration和32bit计数回绕；`TestTimebase.bsv` 测量真实PHY边界；`TestPhyLifecycle.bsv` 覆盖不同长度/速率帧首尾相接。

**B04：修复 Duration 和 NAV。优先级 P0。**

原实现存在注入帧 Duration=0、RTS直接继承、CTS扣减后仍为0，以及NAV被抬高到固定119µs的问题。当前已由MAC根据本次交换生成真实预约时间。

| 已修改的代码 | 原因 | 当前作用 |
|---|---|---|
| `FrameTiming.dataDuration/rtsDuration/ctsDuration/reservation` | 固定值或继承注入值不能覆盖真实DATA和控制帧 | 根据长度、速率、SIFS生成预约；CTS扣减防下溢，Duration超过32767µs时饱和 |
| `MacCore.dcfFsmIdle` 保存 `reservedRts`；`dcfWaitBackOff` 写入DATA/RTS/CTS/ACK Duration | 外部填写的预约值可能缺失或不匹配当前控制速率 | 每次实际发送使用MAC生成的预约；普通ACK设为0 |
| `MacCore.mkNav.tick/handleFrame/resetNav` | 119µs下限制造额外等待；短预约可能错误覆盖长预约；复位原来无动作 | 按接收Duration倒计时，取现有剩余值与新值的最大值；显式复位有效 |
| `MacCore.updateNAV`、寄存器 `0x07C` | 旁听DATA同样可能携带有效预约，需要可控清理实验状态 | 正确接收且非本机目的的RTS/CTS/DATA可更新NAV；MAC空闲时写1清NAV |

本轮采用预约自然到期或显式清零，没有启用“RTS后未听到CTS就提前释放NAV”的可选策略。保留的 `maxNum/phyDelayTime` 等旧寄存器不再参与119µs下限；`sigTime/ofdmSymbolTime` 也不会改变本轮固定20µs头部和4µs OFDM符号公式。

已完成的实施项：

- [x] 在 `NT_SEND_RTS` 发送前计算本次 DATA、CTS、ACK 所需时间，不再依赖测试端填写预约值。
- [x] DATA Duration 设置为 `SIFS + T_ACK`。
- [x] RTS Duration 设置为 `3×SIFS + T_CTS + T_DATA + T_ACK`。
- [x] CTS Duration 设置为 `max(RTS.Duration − SIFS − T_CTS, 0)`，修正原来误用 RTS 时间常量的扣减式。
- [x] 普通单帧 ACK Duration 设置为0，并明确本轮实现范围为无分片、无 TXOP 的普通交换。
- [x] 删除 NAV 对所有短 Duration 的119 µs下限，按合法预约更新；短预约不能缩短已有的更长 NAV。
- [x] 扩展 `updateNAV` 对应处理的帧类型，包括适用的 DATA；只对正确接收且满足地址/Duration语义的旁听帧处理。
- [x] 实现原来为空的 `resetNav`；轮次需要清NAV时显式调用复位，退避状态机的`softRst`本身不清NAV。完整轮次排空与统计隔离仍归B09。
- [x] 明确可选策略：本轮不启用 RTS 预约的提前释放，采用自然到期或显式 NAV 复位；不再统一抬高 Duration。

1038B、54M DATA、6M控制帧时，DATA/RTS/CTS Duration 应分别为60/312/252 µs。这些是测试期望值，生产实现应使用公式。

验收用例：A、B彼此隐藏且均可达中心；A完成RTS/CTS后，B在A的DATA/ACK预约期内不得发射。追加不同包长、不同控制速率、Duration=0、短预约覆盖长预约、NAV自然到期及显式复位测试。

已验证：`TestBackoff.bsv` 检查短NAV不缩短长NAV、零/短预约不被抬高及清零；`TestMacPhyIntegration.bsv` 中隐藏发送端听到中心CTS后，在保护结束前不得发送，且检查6Mbps/24Mbps控制速率对应的Duration。

**B05：修复随机退避和冻结恢复。优先级 P0。**

原生成器缓存两个按旧CW生成的随机值，CW更新后仍可能使用；增窗比较条件会越过上限；冻结恢复跳过IFS。当前已改为按需取样及显式保存恢复状态。

| 已修改的代码 | 原因 | 当前作用 |
|---|---|---|
| `CsmaUtils.mkExpBackoffGenerator.next.get` 删除旧样本预取，按 `(1 << cwExpReg)-1` 掩码取值 | 重试后仍消费旧CW样本会改变碰撞概率 | 每次新退避立即采用当前有效CW，LFSR只在取样时推进 |
| `incrCW/resetCW/putmaccfg`；`MacConfig.backoffSeed` 和寄存器 `0x064` | 窗口越界会落入错误小范围；节点随机流一致不利于竞争实验 | 指数上限10且饱和；成功/最终丢弃复位CW；seed与节点编号混合并避免全零状态 |
| `MacCore.mkCsmaCaBackOff.csmaFSM` 的 `sampled/slots/cycles` | 冻结后重新抽样或跳过IFS都会改变接入概率 | 保存剩余整数slot，恢复先等待完整DIFS/EIFS；未完成slot重新计时 |
| `rememberRx`、`badRx`、`completedIfs` | 单周期CRC失败脉冲可能在恢复时已经消失 | 接收错误状态保留到适用IFS完成，保证需要时采用EIFS |
| `suspendContention`、`savedValid/savedSampled/savedSlots`、`interruptBackoff` | 竞争中需要回复CTS/ACK，不能丢掉本机已抽取的剩余退避 | 先服务SIFS响应，再重新等待DIFS并继续原剩余slot |

seed配置值变化才重置随机序列，同值重写不会回卷；当前可配置的是退避随机流，不能据此声称PHY误码随机种子也可由同一寄存器控制。

已完成的实施项：

- [x] 将随机退避改为按需生成：取新退避值时依据当前有效CW截取随机数，取消已经按旧CW计算的预取队列。
- [x] 保持随机数状态更新和取值行为明确；为重复实验提供可控seed，避免各节点使用相同随机流及非法全零LFSR状态。
- [x] 将增窗改为饱和操作：`cwExp >= cwMax` 时保持最大值，否则加1。
- [x] 对不支持的CW指数报错或明确限制，不能落入产生0～7的default分支。
- [x] 成功后复位到CWmin；最终丢弃后的CW处理与选定参考语义一致。配置同步不能干扰这一过程。
- [x] 增加“新退避/恢复退避”标记，冻结时保存剩余计数。
- [x] 恢复时先等待适用的DIFS/EIFS，再继续原计数；IFS结束时不能重新抽样覆盖剩余计数。
- [x] 重新明确slot计时：遇忙保留剩余整数slot，按协议处理未完成slot，空闲恢复后按完整slot递减。
- [x] 保留足够的接收结果状态以正确选择DIFS/EIFS，避免依赖已经消失的单周期CRC脉冲。
- [x] SIFS响应通路与普通竞争通路明确区分，CTS/ACK及CTS后的DATA不能误进入随机退避；为应答而暂停原竞争时保存剩余slot，并在应答后重新等待DIFS再继续。

验收用例：CWmin=0时全部新抽样为0；失败后立即使用新窗口；成功后下一次新抽样立即回到CWmin；指数10连续增窗仍为10；冻结5个剩余slot后恢复仍是5个；IFS中再次遇忙要重新等待；相同seed可重放，不同节点的随机序列不能全部一致。

已有诊断复现过旧样本 `13,8,0,0,...` 和指数越界后窗口缩为0～7。`TestBackoff.bsv` 已以断言覆盖当前CW取样、指数10饱和、不同节点seed、冻结后保留5个slot、完整slot计时，以及SIFS响应后仍保留4个slot。具体随机样本检查用于复现行为，不替代长期随机分布验收。

**B06：补全活跃信号与持续干扰。优先级 P1。**

原实现接收A时遇到B，只毁掉A并放弃B；A结束后，B的剩余发射时间可能不再约束后来的C。当前已将“正在解码的帧”与“空口仍活跃的信号”分别维护；这是mode 0下也必须修复的问题。

涉及代码：[PHY信号生命周期](/home/gtx/dev/RealEmu/src/PhyCore.bsv:120)、[接收概率判决](/home/gtx/dev/RealEmu/src/ReceptionModel.bsv:104)。

| 已修改的代码 | 原因 | 当前作用 |
|---|---|---|
| `PhyCore.ActiveSignal`、每PHY的16项 `signals` | 只记当前接收帧无法保留其他信号的尾部 | 按源记录有效位、功率、线性功率、结束周期、交换编号和包标识，接收/发射期间均登记 |
| `airClock` 统一处理到期、新到达、CCA和接收状态 | 到期和到达分散更新容易在边界漏判或误判 | 区间按 `[start,end)` 处理；32bit模时钟比较；活动重复事件不延长时间、不重复交付 |
| `energyTerms/interferenceTerms` 及独立门限 | CCA、同步、干扰有效性混用一个条件会掩盖模型含义 | CCA按线性功率总和判断；同步、干扰分别有配置，三个门限默认128（1/32dB单位） |
| `ReceptionModel.beginChunk/lookup/finishChunk` | 碰撞发生后即使干扰先结束，也不能丢失该帧已经碰撞的事实 | mode 0累积碰撞标记，在头部/帧尾使用整包表值，不按bit数做幂运算；有效重叠导致接收失败 |
| `PhyStatus.rxStartFrame/rxFrame`、`txTag` | 旧帧完成与新帧开始同周期时，身份可能串帧 | 同步开始与头部/完成事件分别携带身份；TXEND关联刚结束的交换 |
| `finishDecode` 检查接收交付FIFO是否满 | 上层暂不接收不能无限延长物理信号 | 满时记录“CRC正确但交付失败”并继续物理时间，方便定位非射频丢包 |

**mode 0的具体含义：** `bitModel=False` 为默认；中间区间只传递碰撞历史，`lookup` 在头部结束和帧结束时各使用一次表值，`finishChunk` 累积成功概率并与本帧随机值比较，再应用碰撞否决。因此这里保留的是整包概率表语义及头部判决，不是将每个时间段都按bit数重复计算。无碰撞时最终概率受头部与数据表值共同影响，不能把某一个表项直接等同应用层最终丢包率，也未验证与旧版本随机序列逐帧一致。

mode 1仅在显式将 `0x26C` 写1后启用，才按段内等效bit数计算成功率幂并累积。其16bit概率精度、固定点功率和暂沿用的1mW噪声底仍有限制；原 `mem/Per.mem` 不能直接当单bit概率表。当前保留实现但暂缓启用和标定。

已完成的实施项：

- [x] 为每个接收PHY维护活跃信号记录。当前16节点规模可按发送源保存有效位、功率、结束时间及必要的事件标识。
- [x] 在任何接收机状态下处理新信号的存在时间，包括正在接收另一帧或自身正在发送时；未解码不等于信号消失。
- [x] 使用统一时间基准计算结束时刻；核查到期判断、计数回绕、同周期到达/结束和重复事件处理。
- [x] 当前接收帧结束时只清除自身接收状态，其他活跃信号必须保留到各自结束。
- [x] CCA与干扰计算基于同一套信号生命周期；区分能量检测、接收同步和干扰有效性的判据，避免把一个硬编码门限当成完整PHY模型。
- [x] 第一阶段先实现等功率强信号重叠的完整持续时间语义，让已有干扰影响新帧判决。
- [x] 可选mode 1的单bit成功率查表、时长加权与累积已实现并有定向测试；按当前决定暂不启用，其标定不计入当前mode 0完成条件。
- [x] 核查接收完成同周期到达新帧的碰撞标记，避免读旧值而漏判真实重叠。

已验证：原四项PHY碰撞测试继续通过。`TestPhyLifecycle.bsv` 实际注入A=[10,186)、B=[110,286)、C=[210,386)µs；A与C均失败，且270µs时CCA仍忙，证明B尾部没有随A结束被清除。另测不同长度/速率首尾相接、重复事件和自身发射结束后的外部信号尾部。该测试前半段使用mode 0，后半段显式切到mode 1只做确定性端点等检查；不能把整组日志描述成全部运行于mode 0。

完成证据：各信号开始/结束记录、接收判决和CCA时间线。等功率简化模型与分段SINR模型分别标注，不能仅用一个PASS汇总声称物理层完全对齐。

**B07：重构CTS/ACK等待和响应匹配。优先级 P1。**

原实现把单个超时值用于等待完整响应，合法响应已经开始但未结束时仍可能超时。当前按响应事件分阶段等待，再由参数限制接收开始预算；与ns-3的严格事件/参数对照仍待后续统计验收。

| 已修改的代码 | 原因 | 当前作用 |
|---|---|---|
| `ResponseStage`、`dcfRecvCtsAck` 的 `RESP_TX/START/HEADER/COMPLETE` | 从入队开始计时或等待完整帧都可能误判超时 | 对应TXEND后才启动等待；匹配接收开始后延长到头部，成功头部后再延长到完整响应结束 |
| PHY `rxStart/rxHeader/rxEnd`、`txExchangeId` 和两类接收身份 | 单一“接收开始”标志不能区分同步、头部通过和整帧完成 | MAC可以按实际事件推进阶段，且同周期新旧帧不混淆 |
| `matchesResponse`、内部 `AirFrame.exchangeId`、`PhyEvent.exchangeId` | 迟到ACK、其他节点回应或旧交换回应可能错误完成当前发送 | 校验类型、目标、对端、缓存标识及32bit交换编号；CTS/ACK沿用对应请求编号 |
| 成功与最终失败分支中的出队、CW更新及 `highMacTxRespQ.enq` | 最终失败如果不返回完成握手，上层会一直等 | 一包只完成一次；成功或重试耗尽都释放队列；retryLimit=6最多7次尝试 |

内部类型扩展位于 [Types.bsv](/home/gtx/dev/RealEmu/src/Types.bsv:248)，外部 `MacEvent`、`MpduDigest`、`RfParam` 和DMA桥配置包布局未改变。`exchangeId` 用于核内部交换关联，不是新增到空口802.11帧中的字段。

已完成的实施项：

- [x] 将逻辑等待阶段区分为CTS接收开始、CTS接收完成、ACK接收开始、ACK接收完成；可增加枚举或采用显式子状态。
- [x] 计时从对应RTS/DATA实际TX结束开始，使用一次性事件或明确的armed标记，防止持续电平导致重复启动。
- [x] CTS成功结束该段计时，DATA发送完成后重新启动ACK等待，不能让CTS等待时间跨入DATA阶段。
- [x] 扩展内部`PhyStatus`或事件接口，明确同步开始、有效头部完成、接收结束和CRC状态；当前`rxStart`不能未经定义就等同参考模型的PHY-RXSTART。
- [x] 收到有效接收开始事件后，等待接收结束并设置故障兜底期限；不能在正常回应尚未接收完成时沿用短启动超时判失败。
- [x] 按当前等待状态校验CTS/ACK类型、目标节点、预期对端及内部交换关联，防止迟到响应错误结束新交换。
- [x] 规定旁听帧、CRC失败、非预期响应和纯超时的处理，确保每条路径都能离开等待状态且只更新一次重试计数。
- [x] 保留当前retryLimit=6代表初次加六次重试的语义，并以总尝试次数做测试；不要仅因ns-3属性写7就直接修改。

验收用例：无回应、临界时刻回应、合法回应开始后较晚结束、错误类型、错误对端、迟到CTS/ACK、旁听帧插入、CRC失败、连续失败达到丢弃上限；全部应无死锁、无多次出队、无重复重试计数。

完成证据：每次交换的发送结束、接收开始、接收完成、成功/失败原因及尝试次数时间线。

已验证：`TestResponseTimeout.bsv` 覆盖合法ACK开始后跨越原超时、无CTS/ACK、7次总尝试、旧编号/错误对端/错误类型、CRC失败和诊断计数；三节点集成进一步验证真实MAC与PHY互相驱动时能够完成交换。未以这些定向用例声称已覆盖所有并发时序。

**B08：增加实际状态与诊断计数。优先级 P1，随各修复实施。**

目标是后续板测能回答“配置是否生效、为什么没有收到ACK、帧在哪一层被丢弃”，而不是只得到一条吞吐曲线。

| 已修改的代码 | 原因 | 当前作用 |
|---|---|---|
| `Types.bsv` 的MAC/PHY诊断偏移；版本值 `0x00020000` | 旧驱动回读不能证明新逻辑已部署 | 可辨认诊断接口版本，读取当前配置、CW、NAV和响应阶段 |
| `MacCore.hits/counts/snapshot`、`countEvents`、读写寄存器规则 | 仅知道未收到包，无法分辨等待CTS、等待ACK或重试耗尽 | 12个32bit计数记录输入、DATA/RTS尝试、成功、响应失败、最终丢弃、完成、交付、忽略响应、输入丢弃及CRC失败 |
| `PhyCore.hits/counts/snapshot`、`registerAccess` | 碰撞事件、解码失败与交付FIFO满是不同原因 | 9个32bit计数记录信号、接收启动、CRC成功/失败、重叠帧、发射、重复/非法事件及交付丢弃 |
| 快照、清零和快照序号 | 连续逐寄存器读实时值可能来自不同采样时刻 | 写1锁存本模块计数，写2清零实时计数；清零不修改已锁存快照 |

关键偏移均相对节点MAC基址：`0x050/054/058/05C`为配置代次/时基/CW/NAV；`0x060/064`为控制MCS/退避seed；`0x068/06C/070`为MAC诊断版本/命令/快照序号；`0x074/078/07C`为响应阶段/交换编号/NAV复位；`0x080..0x0AC`为MAC计数。PHY使用`0x214/218/21C`及`0x220..0x240`，门限和模式为`0x260/264/268/26C`，这些偏移已包含PHY的`0x200`。

计数边界：MAC尝试按提交到PHY队列计，PHY发送按实际TXSTART计；MAC完成包括成功和最终失败；向上交付DATA包含重传副本，不能直接当唯一包数。输入未被背压接口接受不算硬件丢包。PHY的CRC成功与交付FIFO满可以同时计数。计数32bit回绕，清零与事件同周期时清零优先；MAC/PHY各自快照，不提供跨模块同时采样保证。

已完成的实施项：

- [x] 增加构建/接口版本、核心频率或cycles/µs、配置生效状态、有效CWmin/CWmax和当前CW指数的读取。
- [x] 记录DATA/RTS发送尝试、成功交换、CTS超时、ACK超时、最终重试丢弃、CRC失败和碰撞标记次数。
- [x] 明确计数单位：一个干扰到达事件、一个失败接收帧、一个失败交换是不同指标，不能共用一个未定义的“collision”计数。
- [x] 为输入队列接收、溢出/丢弃和处理完成设置清楚的观察边界，便于核对事件流。
- [x] 定义计数器位宽、清零和一致读取方法；窄总线读宽计数器时需要锁存或快照，避免跨次读取撕裂。
- [x] 新寄存器使用未占用偏移，更新`Types.bsv`中的映射与说明；MAC/PHY现有处理器可路由时，无需仅为新增偏移改动整个AXI-Lite桥。
- [x] 保持内部`PhyStatus`扩展与外部DMA包格式的边界明确；若确需修改外部格式，必须增加版本并安排对应驱动适配。

验收用例：构造一次成功、一次CTS失败、一次ACK失败和一次最终丢弃，逐项核对计数；多节点寄存器互不串扰；读取诊断状态不会改变正常MAC/PHY行为。

已验证范围：`response`检查MAC成功/失败/完成及快照清零，`lifecycle`检查PHY信号/重叠/重复/CRC/交付满及快照清零；生产RTL有16组MAC/PHY诊断实例。多节点同时读快照和长时间计数回绕仍可作为后续统计台补充用例，不由RTL实例数替代行为证明。

**B09：建立回归与生成RTL验收。优先级 P0，贯穿实现。**

当前状态为部分完成：新增正式断言测试、统一执行脚本、10组功能回归及完整16节点RTL检查已完成；原隐藏节点长统计台仍有未修复的统计问题。

**已修改的测试与构建代码**

| 文件或入口 | 具体修改 | 原因与作用 |
|---|---|---|
| [test_bluespec.py](/home/gtx/dev/RealEmu/scripts/test_bluespec.py:16) | 集中登记测试台、顶层和完成标记；保存独立构建/运行目录、RAM副本、命令、源码摘要和结果；超时清理进程组 | 避免旧日志混入、并发测试共享RAM、编译失败被当作仿真成功，以及超时后遗留进程 |
| 同一脚本的编译与判定逻辑 | 使用`-check-assert`、将G0021作为错误、扩大BSC编译栈；检查退出码、完成标记和FAIL/WATCHDOG；P2P额外核对全部case和收包数 | 从“能启动或打印日志”提升为可追溯的功能回归；C++仿真构建用`-O1`缩短编译时间，不是修改协议时间 |
| [TestP2P.bsv](/home/gtx/dev/RealEmu/test/TestP2P.bsv:103) | 共享`mkTestP2PWithParams`；保留完整16档入口，新增`mkTestP2PSmoke`的MCS7、RTS开关、每档2个突发包加1个延时包 | 用实际16节点顶层、DMA/AXI-Lite和信道验证完整路径，缩短功能检查；通过短测不能代替完整矩阵或稳态统计 |
| [TestMacPhyIntegration.bsv](/home/gtx/dev/RealEmu/test/TestMacPhyIntegration.bsv:11) | 新建3个MAC+PHY，执行16组MCS×RTS、CTS NAV保护和24Mbps控制帧交换 | 将公式和模块断言推进到真实模块联动；没有新建原计划中的`TestHiddenNav.bsv`，NAV集成用例已放在本文件 |
| [TestPhyLifecycle.bsv](/home/gtx/dev/RealEmu/test/TestPhyLifecycle.bsv:59)、[TestReceptionModel.bsv](/home/gtx/dev/RealEmu/test/TestReceptionModel.bsv:28) | 分别检查信号尾部/边界/重复事件/交付满，以及可选概率模块和模式差异 | 把物理信号是否仍存在与概率算法是否工作分别验证；mode 1用例不是启用mode 1的配置要求 |
| `TestChannel.bsv` | 构造测试`PhyEvent`时补齐`exchangeId: 0` | 适配扩展后的内部结构，使原独立信道测试保持可编译；真实交换编号的收发关联由PHY与MAC集成用例验证 |
| `TestBsvTop_collision*.bsv`、`TestPhy.bsv`、`TestBsvTop_hidden_v2.bsv`、`TestBsvTop_bianchi.bsv` | 统一时基，补齐相关测试接线或元数据，旧日志路径改为运行目录内相对路径 | 保持旧测试能够使用当前接口和时间单位；hidden/Bianchi尚未因此获得新的完整统计验收结果 |

**最近一次通过的10组测试**

统一结果目录：`test/build/b03-b08-delivery-20261023/`。每组的`simulation.log`保存运行证据，[results.json](/home/gtx/dev/RealEmu/test/build/b03-b08-delivery-20261023/results.json)汇总结果；`sources-sha256.json`记录源码/测试/表文件摘要，`commands.json`记录实际命令。

| 测试组 | 实际测试文件 | 已验证的行为及范围 |
|---|---|---|
| config | `TestMacConfigApply.bsv` | 顶层寄存器配置、IFS/CW/NAV行为、非法写入和延迟应用 |
| timebase | `TestTimebase.bsv` | 250cycles/µs、slot重配、真实PHY 1038B/MCS7发射44000周期 |
| timing | `TestFrameTiming.bsv` | 524288组长度/MCS公式结果、控制速率、Duration和回绕；不是52万个完整包收发统计 |
| backoff | `TestBackoff.bsv` | 当前CW取样、指数10饱和、节点seed差异、冻结、EIFS/DIFS恢复、SIFS响应后原slot保留、NAV |
| collision | `TestBsvTop_collision_v2.bsv` | mode 0四项：强信号可收、强信号重叠丢包、弱信号不同步、门限下弱信号不破坏强帧，4/4通过 |
| lifecycle | `TestPhyLifecycle.bsv` | mode 0链式尾部、不同元数据、边界、重复事件、TX期间到达；后半段显式mode 1端点及诊断/交付满检查 |
| reception | `TestReceptionModel.bsv` | 人工设定单bit概率下的时长加权、累积、两模式碰撞判决差异及标签；不是mode 0实际PER曲线标定 |
| response | `TestResponseTimeout.bsv` | 响应开始后延长等待、无CTS/ACK、最多7次尝试、错误/旧响应过滤及MAC诊断 |
| integration | `TestMacPhyIntegration.bsv` | 默认mode 0，3个真实MAC+PHY；16组MCS×RTS、隐藏节点CTS保护、24Mbps控制帧，中心共收19帧 |
| p2p-smoke | `TestP2P.bsv: mkTestP2PSmoke` | 默认mode 0，真实16节点顶层内点对点；RTS off/on每档突发2/2、单包延时1/1 |

PASS表示用例的预期行为成立。碰撞用例预期丢包时，正确丢包才是PASS；不能把10/10理解为“所有包都收到”或“整体丢包率为零”。

`integration`为确定性协议流程检查：发送节点CWmin/CWmax及重试上限置0，有利于精确观察交换和保护时序，不用于估计长期竞争吞吐。隐藏节点用例是在中心CTS发出后让另一个隐藏发送端有包待发，检查其没有提前突破NAV，不代表所有同时竞争组合都已覆盖。

`p2p-smoke`主动将成功率表灌为`0xFFFF`，验证链路能够收发，不能验证中间概率的丢包行为。日志RTS off/on分别打印33/22Mbps和374/592µs；吞吐来自每档两个突发包，不能作为稳态性能。日志中的`rtt`实际是发送请求注入到接收数据交付的时间，不能当严格往返时延。证据见 [P2P短测日志](/home/gtx/dev/RealEmu/test/build/b03-b08-delivery-20261023/p2p-smoke/simulation.log:343)。

历史完整`p2p`和`hidden`在B01/B02阶段分别达到3600秒墙钟超时，未通过完整验收；它们不属于上述10组。当前版本的长统计通过记录尚未建立。脚本现有`hidden`判定只要求8档完成且各档有接收，即使未来运行完成，也不能仅据该标记宣称统计口径正确或与ns-3一致。

**RTL与构建检查**

生产顶层`mkRawEmuCore`已生成7个设计Verilog模块，输出位于`backend/build/b03-b08-delivery-20261023/`，生产BSC编译无warning/error。[RTL结构检查](/home/gtx/dev/RealEmu/backend/build/b03-b08-delivery-20261023/rtl-check.json)确认16节点、256条活跃信号记录、192个MAC/144个PHY计数器、16组SIFS响应中保存的退避slot、配置写路径、NAV配置选择及250周期微秒时基，外部DMA结构与Git基线一致。

测试台构建有3条已记录的G0010调度提示：独立退避测试的配置优先级1条，三节点信道单入口注入仲裁2条；没有G0021规则永不执行错误。`Per.mem`未初始化的8960–16383地址不属于8种MCS实际查询的0–8959范围。新增资源和组合路径风险已记录，但本轮没有Vivado综合/布局布线资源与250MHz时序通过报告。

复现本次10组功能回归：

```bash
cd /home/gtx/dev/RealEmu
export PATH=/home/gtx/env/bsc-2025.01.1-ubuntu-22.04/bin:$PATH
python3 scripts/test_bluespec.py --timeout 600
```

这是复现命令，不是本次文档更新重新执行仿真的声明。默认10组中的可选模式单测不会改变生产代码默认mode 0。后续完整入口可用`--tests p2p hidden`选择，但应先完成下面的统计修复。

**剩余待办及完成条件，按执行顺序排列**

- [x] 建立模块断言、短集成回归、独立日志/RAM目录、源码摘要和命令记录。
- [x] 检查BSC调度、生成生产顶层Verilog，并核对配置/时间/新增状态进入RTL。
- [ ] B09-1，修复唯一包统计：`TestBsvTop_hidden_v2.bsv`的`lastSeq`和`txSeq`均从0开始，`sq > lastSeq[src]`会漏计首个seq=0。增加有效位或可靠的唯一包集合，处理重复、序号回绕；用首包、重传副本和边界序号断言验收。
- [ ] B09-2，隔离轮次：为注入包、接收和完成事件保存轮次归属；切换前排空或明确剔除旧轮次残留，固定预热/测量/排空窗口。验收旧轮次迟到帧不进入新轮次吞吐，收发和最终完成数量可核对。
- [ ] B09-3，配置负载与饱和证据：将当前每源1ms固定注入、每档20ms窗口参数化，分别验证低负载和饱和竞争；记录输入接受、发送队列积压、完成和丢弃，不能把未接受的背压请求算作硬件丢包。
- [ ] B09-4，mode 0概率统计：固定MCS、功率、包长并排除碰撞，验证全成功/全失败和若干中间PRR；先令头部表项为全成功以隔离数据判决，再测头部与数据共同作用。MCS0头部/数据共享表项时单独说明期望关系；采用足够样本和明确误差标准，避免把表值直接当最终应用丢包率。
- [ ] B09-5，mode 0碰撞和重试统计：在修正后的隐藏拓扑中覆盖RTS开关、不同发送端数及可配置退避seed；分开统计PHY CRC失败、MAC响应失败/重传、重试耗尽和唯一包交付。PHY误码随机流当前按节点固定初始化，如需独立误码seed实验，应先明确增加相应配置或可控测试入口。
- [ ] B09-6，完成长统计回归：运行完整P2P、hidden及全可感知Bianchi对照，保存配置、seed、源码摘要、逐源结果、窗口和多次运行的离散程度；补充真正的统计断言。平均吞吐接近某个参考值本身不作为通过条件。
- [ ] B09-7，板级实现：`run261023`已完成综合/布局布线和bit生成，16节点新版诊断ABI、250周期时基及mode0板上读回通过；**250MHz时序及基础板测失败，不能关闭此项**。先按实现报告检查`PhyCore.airClock`的信号聚合、MAC/PHY间组合就绪传播和诊断读回路径，切分流水、处理扇出并重跑时序/生命周期/响应回归；实现时序通过后，重新验收静态快照稳定性、连续DMA、单包成功、7次最大尝试和pending归零，再扩大到隐藏节点统计。详见[板测报告](/home/gtx/dev/RealEmu-driver-20261009/tests/board-hidden-20261024/REPORT.md)。新增有界板测工具不代表旧统计台B09-1至B09-6已完成。
- [ ] B09-8，ns-3同条件对照：确认参考源码和配置可复现，统一帧长/有效载荷、控制速率、CW、重试、误码语义、负载、去重及统计窗口后比较多seed结果；采用mode 0时明确两端物理误码模型是否一致。

这些统计需使用不同分母：PHY CRC失败比例只针对进入解码并产生判决的接收帧，包含不了所有未同步信号；MAC最终丢弃比例基于可追踪且已经完成的输入包；goodput基于固定窗口内去重有效载荷。三者不能混用为一个“丢包率”。

原始问题诊断可追溯到 [MAC/退避诊断](/home/gtx/dev/realemu-hidden-analysis-20261022/TestHiddenAudit.bsv)、[PHY连续重叠诊断](/home/gtx/dev/realemu-hidden-analysis-20261022/TestPhyOverlapAudit.bsv) 和 [根因报告](/home/gtx/dev/realemu-hidden-analysis-20261022/ANALYSIS.md)。这些是修复前证据，修复后结论以本轮冻结源码回归为准。

**分批交付与完成标准**

| 批次 | 包含任务 | 已有交付物与证据 | 当前状态 |
|---|---|---|---|
| 第一批：基础配置和时间 | B01、B02、B08必要状态 | 配置路径、250周期时基、config/timebase及RTL检查 | 功能已完成；以最新时长结果覆盖历史14周期额外开销 |
| 第二批：接入和预约 | B03、B04、B05及对应B08 | FrameTiming、Duration/NAV、CW及冻结恢复；timing/backoff/integration | 功能已完成；板级时序未验收 |
| 第三批：接收与失败处理 | B06、B07及剩余B08 | 活跃信号、mode 0碰撞历史、响应阶段、诊断；collision/lifecycle/response | 功能已完成；mode 1保留但暂缓启用与标定 |
| 第四批：集成与统计验收 | B09 | 10组功能回归、生产RTL、run261023实现及首轮板测记录 | 部分完成；实现时序和基础板测失败，统计及ns-3对照待办 |

每批应保存对应源码版本和配置。修改相互依赖时，以完整批次作为可运行检查点，避免拿临时不一致的MAC/PHY组合做吞吐结论。

**需要后续配套的外部事项**

Bluespec功能完成后还需要：FPGA实现时序通过；驱动修复完整ID去重、轮次隔离和固定统计窗；恢复或重新建立可追溯的ns-3参考配置；执行同条件多seed对照。B09已列出验收依赖，其中驱动、ns-3和板级实现需要对应工程配套，不能用Bluesim通过替代。

原分析记录的外部问题包括run261021实现时序未收敛、Case2精确复现源码缺失。新工程run261023仍未收敛，且2026-10-24实际基础板测失败，不能关闭板级问题。当前通过结论仍限于已列出的Bluesim功能场景、mode0默认配置及RTL生成；后续先恢复板级可靠性，再补mode0统计证据。mode1标定保持暂缓。
