# 新固件隐藏节点与 ns-3 的对齐分析及最小修改建议

日期：2026-10-26。对象：本次 D01—D03、T01/T02、C01/C02 修复后的新 bitstream，以及 16:57—17:10 的板测。本文仅分析已有证据，没有修改生产代码、写板卡寄存器或重新执行无线实验。附带工具指南作为历史资料使用，其中的操作步骤不是本轮指令。

## 1. 结论

**目前没有与原 ns-3 Case 2 对齐。** 单发送者 off 相差 −4.54%、on 相差 −13.35%；多发送者的缺口扩大到约 39%～81%，RTS 也没有表现出基准中的持续保护收益。N=2/off 比 N=4/off 还低，不能用统一时钟比例或一个固定开销解释整条曲线。

当前最值得先处理的是三个方面：

1. **实验实际参数不同。** 当前后半段板上全部 16 节点读回 CWmin/CWmax 指数为 4/6，即窗口 15～63；参考为 15～1023。新的上层测试没有像旧直发测试那样请求写 CWmax=10。队列、控制帧速率的核验程度及业务注入路径也不同。
2. **RTS/CTS Duration 与 NAV 仍不正确。** 对当前 1062B、54Mbps DATA 和 6Mbps 控制帧，CTS 应保护 256µs，现有代码得到约 119µs，缺少 137µs。配置现在能到达 NAV 模块，但传进去的预约时间本身仍不正确。
3. **吞吐来自完整主机链路，不能直接当作无线模型吞吐。** sendto 成功、driver 入队、实际 DMA 完成、目的端 DATA 到达和源端 ACK 完成是不同事件。本次大多数应用包没有对应的 driver DATA 入队日志，且返回语义存在“DATA 已到即给上层 ACK”的简化。

普通重试时的旧随机退避样本、冻结恢复、应答匹配以及 PHY 干扰尾部/整包概率近似也仍存在差异。没有逐因素控制变量实验，本文不为这些原因编造贡献百分比。

**本轮没有复现此前的持续死锁。** 五种规模的负载后连通性都恢复，N=8/N=15 后状态采样为空闲，N=4 和 N=15 后的基础回归均 4/4 PASS。因此，“修复死锁有效”与“已对齐 ns-3”是两个不同的验收结论。

## 2. 数据依据、身份与可比范围

### 2.1 本次板测

原始数据与对账见 [本批板测报告](/home/gtx/dev/RealEmu-driver/tests/results/fw-tc-nav-20261026-hidden-165730/report.md)、[十组原始汇总](/home/gtx/dev/RealEmu-driver/tests/results/fw-tc-nav-20261026-hidden-165730/experiment-results.json)。

- N 表示外围发送者数，不含中心 node0；N=1/2/4/8/15，总节点数 N+1。
- 每组预热 1 秒、正式到达窗口 5 秒、排空 2 秒，仅一次测量。
- UDP payload=1000B，driver 实际 DATA=1062B，不含 FCS；固定内部 MCS7，对应 legacy OFDM 54Mbps。
- RTS off/on 阈值 2347/100，分别启动 driver；对于 1062B DATA，off/on 的触发关系正确。
- 用户报告已烧写本次新 bitstream，没有板上固件 ID 回读。当前审查的 BSV 源码与该 Vivado 工程生成清单的哈希全部一致；不能把它表述成已读取硬件逐位指纹。
- 测量数据有效 10/10；严格事件验收 5/10。严格 FAIL 的测量可用于问题分析，不能当作最终校准验收通过值。

### 2.2 ns-3 参考

使用原 [Case 2 测试点 CSV](/home/gtx/dev/RealEmu-driver-20261009/tests/intro_case1_case2_test_points.csv) 中 `case2_hidden_terminal / ns3` 行及其 [测试说明](/home/gtx/dev/RealEmu-driver-20261009/tests/intro_case1_case2_test_points.md:117)。这是已有保存数据，不是本轮新跑的结果，也不是未经核验的“官方标准值”。

其说明记录：802.11a/54Mbps、1000B UDP、每流配置 100Mbps、5 秒、10 次运行中位数及 bootstrap 95% CI；STA↔AP 为 −40dBm、STA↔STA 为 −110dBm；100-packet 队列、short/long retry limit=7；RTS 阈值 65535/0。

本机保留了 CSV 和说明，但说明所链接的 `raw/case2_matrix_v3/reproduction_sources/.../hidden-terminal.cc`、200 次原始样本及精确复现版本未在检查的目录中找到。本机另一个 ns-3 源码树 HEAD 为 `03bb81ad8430af7814c13ee4b03895853d91bbc8`，可用于核查实现语义，**不能自动当作原 Case 2 运行源码和配置的逐位复现**。尤其不能把其他 P2P/Bianchi 脚本的 ControlMode 当作本 Case 2 已确认的控制帧速率。

### 2.3 N=15 不能与 N=16 算同点误差

本次板卡只有 16 个总节点，最多 15 个发送者；参考点 N=16 是 16 个发送者加接收者。共同点只有 N=1/2/4/8。

本次 N=15/off/on 为 0.7344/0.8096Mbps；参考 N=16 为 2.4152/17.4600Mbps。它们可帮助观察趋势，但不是相同工作负载，本文不插值、不把它们作为同 N 点计算百分比。最小补齐办法是在 ns-3 增加 N=15，而不是扩展 FPGA 节点数。

## 3. 数值和趋势没有对齐

相对差异 = `(RealEmu/ns-3 − 1) × 100%`。

| 发送者 N | RTS | ns-3 Mbps | 新 RealEmu Mbps | 相对差异 |
| --- | --- | --- | --- | --- |
| 1 | off | 24.8320 | 23.7040 | -4.54% |
| 1 | on | 19.8848 | 17.2304 | -13.35% |
| 2 | off | 19.4984 | 6.1744 | -68.33% |
| 2 | on | 19.1120 | 7.3968 | -61.30% |
| 4 | off | 12.5392 | 7.7040 | -38.56% |
| 4 | on | 18.0856 | 7.2496 | -59.92% |
| 8 | off | 6.2744 | 3.4400 | -45.17% |
| 8 | on | 17.6680 | 3.4432 | -80.51% |

没有预先约定数值容差，不能因为 N=1/off 只差 4.54% 就宣布校准通过。参考 CI 描述 10 次 ns-3 样本中位数的估计不确定性；RealEmu 只有一次样本，没有自己的 CI，不能据此做正式的显著性检验。

![共同发送者数量下的 UDP goodput 对照](/home/gtx/dev/RealEmu-driver/tests/results/fw-tc-nav-20261026-hidden-165730/ns3-alignment/common-n-goodput.png)

图只画共同 N，ns-3 带原 CSV 的 CI，RealEmu 不补造误差条。

| N | ns-3 on/off | RealEmu on/off |
| --- | --- | --- |
| 1 | 0.801 | 0.727 |
| 2 | 0.980 | 1.198 |
| 4 | 1.442 | 0.941 |
| 8 | 2.816 | 1.001 |

参考在 N=8 开启 RTS 后吞吐约为 off 的 2.816 倍；本次仅约 1.001 倍。参考 on 曲线从 N=2 到 N=8 基本保持在 17.7～19.1Mbps，本次从 7.40 降至 3.44Mbps。这是保护机制/竞争与上层供给共同作用的明显差异，不只是单发送者控制帧开销。

## 4. 参数与语义逐项对照

| 项目 | 本次 RealEmu | 原 ns-3 参考或本机实现 | 判断 |
| --- | --- | --- | --- |
| goodput 的字节单位 | 接收的唯一 1000B UDP payload | UDP PacketSink payload | 主要 Y 轴字节层一致 |
| 统计窗 | 墙钟，预热1s后固定到达窗5s，另排空2s | 仿真时间5s；精确启动/预热需原脚本 | 不足以声明完全同窗 |
| 重复实验 | 每条件1次 | 每条件10次，中位数 | 未对齐 |
| 业务输入 | 每源请求100Mbps，socket实际约56～57Mbps | 配置100Mbps/源 | 配置/实际输入不能混同 |
| 流量路径 | hwsim/IBSS→Netlink→driver→共享DMA→FPGA→driver→内核UDP | ns-3 应用→Wi-Fi模型→PacketSink | 主机路径和队列不同 |
| 目标/隐藏链路 | SNR正负映射为距离8/1023；不是逐值SNR校准 | 矩阵RSS −40/−110dBm | 仅验证可达/隐藏，未对齐功率与干扰 |
| DATA 速率 | 实际内部MCS7/54Mbps | 54Mbps | 本档速率一致 |
| 控制帧速率 | RTS/CTS/ACK均固定6Mbps | 原复现源码缺失，不能直接确认；单源时间特征更像较快控制帧 | 需实测/恢复原配置 |
| CWmin | 指数4→15 | 15 | 相符 |
| CWmax | 读回指数6→63 | 参考说明及本机11a默认1023 | 明显不同 |
| CW变更后的随机样本 | 配置更新会清预取；普通incr/reset未清 | 按当前CW生成新退避 | 仍不等价 |
| 忙后恢复退避 | 直接SUSPEND→BACKOFF；全局slot相位 | 需要适用IFS/slot边界 | 仍不等价 |
| RTS/CTS NAV预约 | 180→116→下限119µs | 应覆盖剩余交换 | 当前实现不正确 |
| ACK/CTS等待 | TX_END后等完整应答，timeout300µs | 本机初始等有效RX开始，随后延至RX结束 | 不能只改成相同数字 |
| 重试 | 读回6；当前RTL初次+最多6次重试 | 参考配置7；需确认计数定义 | 先对齐尝试次数，不能只按整数判差1 |
| 队列 | host共享TX1024；每MAC输入10，另有小FIFO/Linux队列 | 说明为100-packet Wi-Fi队列 | 未对齐 |
| PHY时长 | 已含SERVICE+tail 22bit；250cycles/µs | 11a OFDM时长公式 | 已修复基础差异；FCS/帧型边界需核验 |
| PHY判决 | mode0整包表+强重叠否决 | 本机ns-3按接收区间SINR/误码模型计算 | 只能寻求约定范围的近似一致 |
| 上层成功 | 目的端DATA事件被当作源端ACK成功 | RX交付与TX完成不同事件 | 仍不等价 |

hwsim 前端使用 2412MHz/IBSS，driver 将 rate_idx=11 映射到内部MCS7；FPGA仍使用其802.11a常量。不能只看到前端2.4GHz就断言 FPGA 自动加入 ERP 的6µs扩展，当前没有这种证据。但前端QoS/帧头/队列与参考AP/STA配置仍应冻结核对。

## 5. 第一项明确差异：CWmax 实际为63

### 5.1 证据与形成路径

本批 N=8/15 前后四组只读采样、每组3次、每次16节点，均读回 CW_MIN=4、CW_MAX=6、TIMEOUT=300、RETRY_LIMIT=6。对应文件在 [只读状态目录](/home/gtx/dev/RealEmu-driver/tests/results/fw-tc-nav-20261026-hidden-165730/followup/20261026-170711-followup-0b1twr4a)。N=1/2/4没有逐阶段配置快照，不能声称已逐阶段读回；源码默认和测试写路径支持同样的默认配置解释。

[Types.bsv](/home/gtx/dev/RealEmu/src/Types.bsv:109) 默认 cwMax=6；旁边 `//1023` 注释有误，实际是 `2^6−1=63`。[realwmediumd.c](/home/gtx/dev/RealEmu-driver/realwmediumd/realwmediumd.c:716) 本实验启动时只写 RTS_THRESH，没有写 CW_MAX。软件 wqueue 的15/1023是其软件队列参数，不会自动写进 FPGA 退避模块。

历史指南的 `CFG_CW_MAX=10` 属于旧 `test_hidden_terminal.c` 直发工具。当前跑的是 hwsim 上层 star 实验，不能把旧工具常量算成本次真实配置。[本机ns-3默认配置](/home/gtx/dev/ns-3-dev-git/src/wifi/model/wifi-mac.cc:940) 的非11b CWmin=15、CWmax=1023，也与参考说明相符。

C01 已修复顶层配置到退避/NAV的传播，所以目前不是“写了10但没生效”的旧问题，而是本次测试没有请求写10。

### 5.2 为什么影响多节点

两边指数序列分别为：

```text
当前：15 → 31 → 63 → 63 → ...
目标：15 → 31 → 63 → 127 → 255 → 511 → 1023
```

高碰撞时窗口过小，更容易持续重复竞争；CW=63 的平均随机等待为31.5slot≈283.5µs，而1023对应511.5slot≈4603.5µs。这是上限等待的比较，不是每包都等后者，更不能把16倍窗口直接换算成16倍吞吐。

最小验证无需改默认RTL：停止/排空后用现有AXI-Lite入口写CW_MAX=10并读回所有活动节点，保留timeout300/retry6及其他参数，单因素复测。是否改善多少必须由新A/B回答，本文未执行该修改。

## 6. RTS/CTS 预约少了137µs，是 on 曲线异常的首要协议缺陷

### 6.1 当前代码的预约链

[driver](/home/gtx/dev/RealEmu-driver/realwmediumd/realwmediumd.c:806) 给描述符填的是 DATA 的 `pkt_duration`；1062B/MCS7为180µs。[setRtsFrame](/home/gtx/dev/RealEmu/src/CsmaUtils.bsv:56) 改类型和长度，但继承原 duration。[CTS分支](/home/gtx/dev/RealEmu/src/MacCore.bsv:684) 再减 `SIFS16+CYNC20+RTS_MPDU_TIME28=64`，得到116。[mkNav](/home/gtx/dev/RealEmu/src/MacCore.bsv:148) 把小于默认119的值抬到119。

```text
DATA描述符 duration=180
→ RTS duration=180
→ CTS duration=116
→ 旁听者 NAV=max(116,119)=119µs
```

这条链来自本次工程对应源码及现有默认参数；本轮没有板内抓取四类实际Duration，实际硬件事件跟踪仍是后续验证项。

### 6.2 应有数值与后果

当前20MHz OFDM公式：`T(L,m)=20+4×ceil((8L+22)/NDBPS[m])`，单位µs。当前控制帧固定6Mbps：RTS20B=52µs，CTS/ACK14B=44µs，DATA1062B@54M=180µs。

| 帧 | 当前Duration | 按当前6M控制帧应有Duration |
| --- | --- | --- |
| RTS | 180 | 3×16+44+180+44=316 |
| CTS | 116；旁听时抬到119 | 2×16+180+44=256 |
| DATA | 16+20+20=56 | 16+44=60 |
| ACK | 0 | 0 |

以旁听节点收完CTS为t=0：DATA应从t=16持续到196，ACK从212持续到256。NAV在119到期，即使重新完整等待DIFS34，随机退避为0时也可能在约153发起RTS，撞到仍在接收的DATA。当前SUSPEND恢复还没有完整DIFS，风险更早。

发送者互相听不到DATA，因此补充DATA NAV不是本拓扑的核心替代方案；首先必须修正确实能听到的中心CTS的预约。仅把NAV最小值改成更大的常数不能对齐不同包长/MCS，也可能造成过度保留。

### 6.3 最小改法

复用既有duration字段和时长函数，由driver预计算完整RTS剩余交换时间，setRtsFrame继续传递；DATA在MAC中写SIFS+真实ACK时长，CTS减去SIFS+真实CTS时长。NAV按有效Duration更新已有剩余时间的最大值，Duration0不新增预约，移除任意119下限。需要时再扩展旁听DATA处理。

先把输入描述符duration的契约写清楚，并同步实际driver、独立C测试和BSV测试；不要让“DATA airtime”“RTS剩余预约”和“100ms软件超时”继续共用同一含糊解释。无需增加新的MAC状态机或第二套NAV系统。

## 7. 单发送者差异：控制速率应核验，不能照搬旧文档结论

RealEmu三类控制帧都硬编码MCS0/6Mbps，这是源码可确认事实。原Case2的精确ControlMode/basic rate set未在现有参考文件中保存，不能确定其ACK/CTS都为6M，也不能直接断定为54M。

在单发送者近似饱和条件下，`8000/goodput`给出每个1000B交付的等效时间：

| 数据 | off 等效 µs/1000B | on 等效 µs/1000B | 开启 RTS 增量 |
| --- | --- | --- | --- |
| board | 337.50 | 464.30 | 126.80µs |
| ns3 | 322.16 | 402.32 | 80.15µs |

这些是吞吐推导的等效时间，不是板内逐帧测量。

- 6M控制帧开启RTS的额外开销为RTS52+CTS44+2×SIFS16=128µs，与板测增量126.80µs接近。
- 若RTS和CTS均54M，二者各24µs，额外开销80µs，与参考增量80.15µs接近。
- ACK6M为44µs、54M为24µs；若参考三类控制帧均54M，RealEmu每个on交换多耗28+20+20=68µs，与单源等效周期缺口约61.98µs同量级。

因此“参考使用较快控制帧”是很强的核查线索，但仍是推断。不能把它推广为多节点80%缺口的解释；固定控制帧开销无法解释on吞吐随N崩落。

[本机GetControlAnswerMode](/home/gtx/dev/ns-3-dev-git/src/wifi/model/wifi-remote-station-manager.cc:853) 按basic rate set和请求速率选择ACK/CTS速率，设置ConstantRateWifiManager的ControlMode不自动证明所有响应同速率。后续应恢复原参考脚本/pcap或记录TxVector。

为最小化硬件修改，可额外建立一组明确RTS/CTS/ACK均6M的ns-3校准对照；原Case2数据仍保留，不能把更换参考配置当作已匹配原基准。

## 8. 上层路径与队列：当前未交付不是PHY PER

### 8.1 整轮包数漏斗

下面统一使用预热+正式发流的整轮成功发送及其排空后接收数，不把6秒发送群与5秒到达窗的吞吐混用。driver列只统计长度1062B、实际记录成功入TX队列的DATA，不含ping/隔离控制包，也不是DMA完成计数。

| N / RTS | 应用成功发送（整轮） | driver DATA 入队日志 | UDP 唯一收到（整轮） | 入队/应用 | 收到/入队 |
| --- | --- | --- | --- | --- | --- |
| 1 / off | 42724 | 17883 | 17813 | 41.86% | 99.61% |
| 1 / on | 42738 | 13010 | 12959 | 30.44% | 99.61% |
| 2 / off | 85278 | 5365 | 4708 | 6.29% | 87.75% |
| 2 / on | 85417 | 5982 | 5564 | 7.00% | 93.01% |
| 4 / off | 170591 | 7793 | 5849 | 4.57% | 75.05% |
| 4 / on | 169999 | 7379 | 5481 | 4.34% | 74.28% |
| 8 / off | 342027 | 10222 | 2591 | 2.99% | 25.35% |
| 8 / on | 341060 | 10079 | 2634 | 2.96% | 26.13% |
| 15 / off | 634332 | 17273 | 589 | 2.72% | 3.41% |
| 15 / on | 637515 | 17297 | 610 | 2.71% | 3.53% |

N=2/off有85,278个应用成功发送，只有5,365条对应driver DATA入队日志；N=15/off的634,332个应用包只有17,273条。因此不能把其余包都叫作“已经进入FPGA后发生无线碰撞”。它们可能在Linux/hwsim/Netlink队列里丢弃或等待，或受下游服务速度反压；本轮没有各层丢弃计数和逐包映射，不能唯一定位到某一主机队列。

这是计数级漏斗，没有把应用序号逐一关联到内核帧和cookie；上层重试也可能使同一应用包对应多次提交。因此“入队/应用”不能直接解释成某一个队列的精确准入概率，更不能据此分配各层丢包百分比。

反过来，N=15/off已有DATA入队后的唯一交付比例也只有3.41%，说明不能把全部差异都归给Python发包或主机丢包；已进入driver的请求完成/无线服务同样显著恶化。host供给和无线服务相互耦合，需要两段分别测量。

### 8.2 可见的结构差异

[realemu_hw.c](/home/gtx/dev/RealEmu-driver/realemu-hw/realemu_hw.c:734) 让所有源的DATA共用queue0，软件深度1024；[发送消费](/home/gtx/dev/RealEmu-driver/realemu-hw/realemu_hw.c:867) 在持有队列锁时循环执行阻塞H2C写。[MAC输入队列](/home/gtx/dev/RealEmu/src/MacCore.bsv:394) 每节点深度10，桥接头部如果投向已满节点会反压共享DMA输入。这与ns-3每站独立100包Wi-Fi队列不同，可能造成跨源队头阻塞；本次没有DMA写延迟trace，不能把它宣布为已经证明的唯一瓶颈。

此外每包多条日志、Python调度、Netlink复制和轮询线程会消耗主机资源。实际socket接受约56～57Mbps低于请求100Mbps，但仍高于接收吞吐，不代表空口一定已经按参考方式持续饱和。饱和应通过MAC队列非空率/实际PHY发起率证实。

下一步先增加批次统计/时间戳或独立直发对照，核对DATA入队→DMA写完成→PHY发起→唯一接收→TX完成。不要先增加新调度框架；也不要仅增加发流目标就认为消除了供给差异。

### 8.3 四次DMA读错误与吞吐差距应分开解释

N=8/off一次、N=15/off三次 `read file: Unknown error 512`，全部发生在第一条UDP DATA提交之前的外围隔离探测期间；on阶段没有这些读错误。当前C2H读超时为10秒，而两组预期失败探测分别至少持续约14/28秒，空闲读等待超时是优先解释，尚缺逐次内核trace。

日志中的H2C名称还是读取封装的错误标签，实际调用使用C2H fd，不能把文字当作H2C发送失败证据。错误之后UDP和负载后ping继续工作，最终基础回归也通过。它们使严格验收失败，应该独立修正空闲读/真实传输错误的区分，但不能拿它们解释N=2或N=4的吞吐缺口——这两档根本没有该读错误。

## 9. 退避、应答与完成语义仍不一致

### 9.1 普通增窗/复位仍可能使用旧样本

[CsmaUtils.bsv](/home/gtx/dev/RealEmu/src/CsmaUtils.bsv:104) 的resultQ预取随机退避，普通incrCW/resetCW只更新cwExpReg，未清预取FIFO。C01已保证配置put会清旧样本，也修好了`>=`饱和，不能继续把这些已修项算作当前原因；但失败后实际采用较大窗口、成功后回到小窗口仍可能滞后若干样本。

[MacCore.bsv](/home/gtx/dev/RealEmu/src/MacCore.bsv:314) 的SUSPEND结束后直接回BACKOFF，未重新经过适用DIFS/EIFS；自由运行slot相位可能使恢复首段不足完整slot。多节点下它与短NAV叠加，改变碰撞和重传节奏。

最小方案是保留现有LFSR及FSM，让普通CW变化时旧样本失效，必要时把取样移到next.get；复用现有IFS状态恢复剩余退避，不重新抽样。无需要求随机序列与ns-3逐位相同，但分布、CW上限和冻结规则应相同。

### 9.2 timeout数值不能直接照抄

当前等待完整CTS/ACK，timeout300µs。[本机ns-3](/home/gtx/dev/ns-3-dev-git/src/wifi/model/frame-exchange-manager.cc:579) 从TX_END起初始等待SIFS16+slot9+PHY头20=45µs，[RX开始后](/home/gtx/dev/ns-3-dev-git/src/wifi/model/frame-exchange-manager.cc:290) 延至该次接收结束。

正常6M ACK/CTS在TX_END后已经需要SIFS16+响应44=60µs，再加流水，所以直接把当前整帧等待改成45µs会制造伪超时。300会改变失败后的重试节奏，但调整它既修不好短NAV，也不保证吞吐单调上升。

先保留300把预约/退避修好；再测真实响应边界，选择有依据的整帧等待或复用计数器区分等有效头/等结束。现有rxStart是进入SYNC，不能直接冒充ns-3有效PHY头接收指示。

### 9.3 错应答匹配、RX交付和TX完成

[当前CTS/ACK分支](/home/gtx/dev/RealEmu/src/MacCore.bsv:717) 主要按目的地址和类型接受，没有完整验证预期类型、对端和完整包ID。旧应答可能完成当前队头，或意外帧触发重试；超时判决仍需检查与持续RX队列、合法响应截止同拍的优先级。

目的端收到DATA就产生highMacRxReqQ；真正源端ACK成功走highMacTxRespQ的GenericResp，桥接仅消费。driver把DATA事件当作硬件ACK成功并通知Linux，因此上层可能认为成功，而FPGA源端仍因ACK未收继续重传。

本次168个异常已确认全为相同提交成功后再返回，不是超时后首次晚到；driver丢弃了这些副本，UDP duplicates=0。本机ns-3的[MAC接收中间层](/home/gtx/dev/ns-3-dev-git/src/wifi/model/mac-rx-middle.cc:196) 按Retry和SequenceControl抑制重复。

本批所有阶段显式硬件status=0返回均为0，没有成功DATA事件的请求最终通过driver的100ms软件no-ACK结束。该100ms包含软件排队和等待，与FPGA的300µs应答计时不是同一个参数；不能把软件no-ACK计数直接当成PHY碰撞次数。失败反馈迟缓也可能改变Linux侧队列/后续提交，需要测量失败发生至反馈的实际间隔。

ACK丢失/未接受导致DATA重传是当前重复键的候选解释，不能只凭日志唯一归因为DMA复制。N=4/off重复129相对首次成功5865约2.20%，仅重复计数本身不足以解释几十个百分点goodput缺口；其背后的重传/应答占用可能更大，需要PHY/MAC trace。

应先保证每个请求有限完成、ACK/CTS匹配正确并抑制重复RX交付；如果要严格报告上层ACK，则需独立TX成功/失败完成语义。仅补一个GenericResp不会自动让主机知道真实ACK结果。此接口改动独立评估，不混入最小NAV修复。

## 10. PHY仍是近似模型，保留mode0也能先修边界

### 10.1 强重叠否决不等于ns-3通用碰撞模型

当前有CS门限、SYNC/RX强重叠标记，不能再说“完全没有碰撞”。但本机[InterferenceHelper](/home/gtx/dev/ns-3-dev-git/src/wifi/model/interference-helper.cc:563) 按接收区间变化的干扰/SINR计算成功率；未启用capture不代表任意两帧重叠必然双败。短重叠、强弱功率和噪声会影响结果。

保留mode0意味着每包做一次最终成功/失败判决，完全可以继续使用；它不等于已经与任意ns-3误码模型逐帧统计等价。本轮不建议优先引入分段BER。

### 10.2 干扰尾部仍需独立验证

```text
A=[0,180)µs
B=[100,280)µs
C=[200,380)µs
```

A/B撞后，B不成为当前锁定帧；A结束后C到来时B仍在空口。当前CCA保留最晚能量结束时间，但[PHY_IDLE接收判断](/home/gtx/dev/RealEmu/src/PhyCore.bsv:336) 和collide并未使用独立的“外部强RX仍存在”状态来否决C。CCA还混有本机TX，不能直接拿它替代外部干扰判断。

旧审计在相同类型A/B/C上复现过C错误成功；当前源码仍保留该逻辑缺口，但没有在新C=250版本上重跑该旧审计，因此本文将它列为“源码仍有风险、当前版本待定向证明”，不把旧日志改称本次仿真证据。

最小方案可在现有时长/标签路径上保存一个外部强RX最晚结束时间，覆盖未锁定帧和本机TX期间到达的信号，不需要逐节点干扰表。边界采用[start,end)，刚好衔接不能误判碰撞。

### 10.3 整包表与噪声累计还需校验

[noiseSum/currentmax/cycleCount](/home/gtx/dev/RealEmu/src/PhyCore.bsv:526) 的清理规则受SYNC/RX状态guard限制；帧完成转IDLE后rxEnd清理是否落在有效规则周期需单独证明。SYNC查表结果保留后仍没有作为最终DATA否决项使用，需明确这是mode0的有意简化还是遗漏。

最终PRR表地址只有SINR与MCS，没有当前包长维度；长度变化依赖原表校准范围，不能自动等价于ns-3随比特数变化的PER。若要同时代表不同长度DATA及短控制帧，必须说明标定包长或补恰当的概率换算。

目标/隐藏功率也未严格校准：driver把SNR>0全部映射d=8、其余d=1023，txPower固定2000；当前ROM给loss约578/1926，接收定点1422/74，CS门限128。它验证了两类链路的同步/侦听差异，却不是−40/−110dBm矩阵的逐值复现，隐藏弱信号是否仍贡献噪声也应核对。

这些缺陷的方向不完全相同，例如遗漏干扰尾部可能增加错误成功，短NAV/过小CW则可能降低成功率；不能由总吞吐偏低反推每个PHY问题都一定使吞吐偏低。

## 11. 已修问题不能继续列为本轮根因

| 历史问题 | 当前证据与边界 |
| --- | --- |
| MAC/PHY使用200cycles而user_clk250MHz | 当前统一250；工程源码哈希匹配，计时定向仿真通过 |
| 负setup slack | 本次具体实现WNS+0.002ns、WHS+0.009ns，已通过；裕量小，但无证据可据此归因当前偏差 |
| 顶层配置不传播到退避/NAV | C01已修并有功能仿真；本次CWmax小是未请求改默认值 |
| CW等于上界继续越界 | `>=`饱和已修；普通重试预取问题仍需处理 |
| 短脉冲/桥接背压造成事件丢失 | D/C定向回归已覆盖；本轮重复返回不自动证明这些修复无效 |
| PHY缺SERVICE+tail22bit | 当前 [时长输入](/home/gtx/dev/RealEmu/src/PhyCore.bsv:247) 已加22，不能再按旧静态报告建议盲目加7B |
| 旧C工具低16bit去重/首末包时间窗 | 本次全run ID/源/完整序号，固定窗；旧测量bug不适用于这批 |
| 持续DCF等待、PHY空闲、FIFO满 | 本轮负载后未复现；有限测试不能替代长期稳定性证明 |

1062B DATA缺FCS这一点仍须说明，但1062/1064/1066B在54M下都落在40个OFDM符号、180µs，同档几字节长度差不足以解释N=8/on的80.5%缺口。其他长度/MCS的边界要逐项算，不能据此一概忽略FCS。

## 12. 推荐的最小修改与验证顺序

| 顺序 | 工作 | 修改范围 | 必须取得的证据 |
| --- | --- | --- | --- |
| A0 | 冻结参考版本、完整参数和N=15；核实真实控制速率 | 测试记录/ns-3配置 | 原脚本或可复现快照、RTS/CTS/ACK TxVector或pcap、明确队列/窗口 |
| A1 | 用现有接口配置CWmax10并核实 | 测试配置，不先改RTL默认 | 活动节点读回；同负载同窗口下63↔1023单因素A/B |
| A2 | 修RTS/CTS/DATA Duration和NAV | driver既有字段+CsmaUtils/MacCore局部 | 316/256/60/0；旁听CTS保护到ACK结束；不同包长/MCS同样正确 |
| A3 | 修普通CW样本失效和忙后IFS恢复 | 现有退避FIFO/FSM | 增窗/复位首个样本正确；保留剩余退避；完整IFS和slot |
| A4 | 明确应答匹配、重试与最终完成 | MacCore局部分支，必要时独立driver事件契约 | 错类型/对端/ID不完成；ACK丢失可重传但不重复交付；每请求完成一次 |
| A5 | 核查host与DMA供给，并做直发对照 | 批次统计/现有测试工具 | 软件入队、DMA完成、MAC队列非空率、PHY发起/接收/重试分别统计 |
| A6 | 修mode0干扰尾部和帧间累计清理 | PhyCore局部标量/现有流水 | A/B/C、TX期间外来尾部、帧尾同拍、前后包状态隔离 |
| A7 | 再评估timeout与PHY概率标定 | 参数/必要的局部接收等待阶段 | 成功与失败分开验证，明确等RX开始还是等完整帧 |
| A8 | 同参重复实验并给出容差 | 测试与分析 | 共同N各10次、完整ID及无晚到、独立CI；按预先约定标准验收 |

建议先完成A1+A2，再看on曲线是否恢复，避免同时大改MAC和PHY而失去归因能力。复用既有字段、时长函数、IFS状态、LFSR和FIFO；不新增第二套调度/配置/NAV框架，也不要求改成分段BER。

后续基础协议仿真应至少覆盖：CW0与上限、忙后恢复、CTS旁听预约、合法/错误/截止边界应答、ACK丢失重传、A/B/C干扰尾部；再跑已有33个不同回归用例。最终改RTL需重新实现时序验收和板测，不能只看到仿真PASS就宣布ns-3数值一致。

当前“协议功能正确”“相同参数下曲线趋势一致”“数值在约定容差内”应分三层验收。用户尚未指定数值容差，本文不自行宣布5%或10%为通过标准。

## 13. 本次产物与复核方法

- [同N逐点误差CSV](/home/gtx/dev/RealEmu-driver/tests/results/fw-tc-nav-20261026-hidden-165730/ns3-alignment/same-n-comparison.csv)
- [整轮发送—driver—UDP包数CSV](/home/gtx/dev/RealEmu-driver/tests/results/fw-tc-nav-20261026-hidden-165730/ns3-alignment/all-round-funnel.csv)
- [RTS收益CSV](/home/gtx/dev/RealEmu-driver/tests/results/fw-tc-nav-20261026-hidden-165730/ns3-alignment/rts-gain.csv)
- [完整计算JSON](/home/gtx/dev/RealEmu-driver/tests/results/fw-tc-nav-20261026-hidden-165730/ns3-alignment/analysis.json)
- [来源/版本哈希](/home/gtx/dev/RealEmu-driver/tests/results/fw-tc-nav-20261026-hidden-165730/ns3-alignment/source-review.json)
- [可复算脚本](/home/gtx/dev/RealEmu-driver/tests/results/fw-tc-nav-20261026-hidden-165730/ns3-alignment/analyze.py)，在本机运行即可重建CSV和PNG/SVG。

基准原CSV和说明已拷贝到该结果目录，分析没有覆盖原始数据。所有计算/图表在driver既有Git忽略的批次目录，本文位于RealEmu/doc供后续改动评审使用。新增内容仅为报告和分析产物。
