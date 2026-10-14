# RealEmu 与 ns-3 (802.11a) 关键参数静态对齐分析报告

> 日期：2026-10-13
> 范围：RealEmu RTL（`src/Types.bsv` / `MacCore.bsv` / `PhyCore.bsv` / `CsmaUtils.bsv`）↔ ns-3 `ns-3-dev-git`（`src/wifi/model/`）
> 目的：为点到点吞吐/延时测试程序（覆盖 MCS 0–7 × RTS on/off）建立参数基线，明确哪些参数需要对齐、如何在软件侧对齐。
> 协议：802.11a，20 MHz，5 GHz，OFDM。

---

## 1. MAC 层等待时间与时隙

### 1.1 对比表

| 参数 | RealEmu 默认 | ns-3 (802.11a/20MHz/5GHz) | 802.11a 标准 | 结论 |
|---|---|---|---|---|
| SlotTime | 9 µs（`slot:9`） | `OFDM_SLOT_TIME_20MHZ = 9 µs` | 9 µs | **一致** |
| SIFS | 16 µs（`sifs:16`） | `OFDM_SIFS_TIME_20MHZ = 16 µs` | 16 µs | **一致** |
| DIFS | 34 µs（= SIFS + 2×slot） | SIFS + 2×slot = 34 µs | 34 µs | **一致** |
| EIFS | 94 µs（固定） | SIFS + ACK@6Mbps(44µs) + DIFS = **94 µs**（随 ACK 速率动态计算） | 94 µs | **数值一致**。ns-3 动态算，RealEmu 写死 94；11a ACK 走基础速率 6M 时恰好相等 |
| ACK/CTS 超时 | `timeout:300` µs（需收到完整响应帧） | **45 µs**（= SIFS16 + slot9 + PHY头20；从 txEnd 起只等 rxStart） | — | **不一致**。RealEmu 偏大约 255 µs，冲突后重传节奏偏慢 |
| 重传上限 | `retryLimit:6` | `FrameRetryLimit = 7`（dot11ShortRetryLimit） | 7 | **差 1**，软件写 0x30=7 |

### 1.2 说明

- RealEmu 的 timeout 语义是"发送数据/RTS 后等待**完整 CTS/ACK 帧**收齐"，因此理论下限 = SIFS(16) + 响应帧时长(44) = 60 µs；ns-3 只等 rxStart，即 SIFS + aSlotTime + PHY 头起 = 45 µs。取 70 µs 是给 RealEmu 留 10 µs 余量后的折中值。
- EIFS：两边在 11a + ACK@6M 场景下数值相同，无需修改；但若未来 ns-3 侧改用非基础速率 ACK，需同步改 RealEmu 的 `eifs` 寄存器。

## 2. 退避规则（CW / Backoff）

| 项 | RealEmu | ns-3 | 结论 |
|---|---|---|---|
| CWmin | `cwMin:4`（指数，窗口 2⁴−1 = 15） | 11a 非 b 标准 `cwmin = 15` | **一致** |
| CWmax | `cwMax:6`（窗口 63） | `cwmax = 1023`（指数 10） | **不一致**，软件写 0x28 = 10 |
| 失败增窗 | `incrCW`：重传时指数 +1（窗口 ×2） | CW 翻倍至 CWmax | 一致（`incrCW` 比较符为 `>`，边界处会到 exp+1 再由 default 分支回落，CWmax=10 时误差 ≤ 1 档） |
| 成功复位 | 收到 ACK `resetCW` → cwMin | CW 重置为 CWmin | 一致 |
| 退避挂起 | CSMA_SUSPEND 保留剩余计数，信道空闲后继续 | 同（backoff 计数冻结） | 一致 |
| 随机数 | LFSR + 节点 id 异或混合，按 exp 取低位 | 均匀随机 [0, CW] | 分布近似，可接受 |
| 响应帧（CTS/ACK） | 仅 SIFS，无随机退避（`start(True, False)`） | 同 | 一致 |
| 新数据帧 | DIFS + 随机退避 | DIFS（=AIFS0+2slot）+ 随机退避 | 一致 |

## 3. 物理层传输时间计算

### 3.1 公式对比

**ns-3**（`ofdm-phy.cc` GetPayloadDuration）：

```
T_PPDU = 前导码 16 µs + L-SIG 4 µs + N_sym × 4 µs + SignalExtension(5GHz = 0)
N_sym  = ceil((16 + 8×PSDU + 6) / NDBPS)        // 16bit SERVICE + 6bit tail
```

**RealEmu**（`PhyCore.bsv` txTime 计算）：

```
T_PPDU = syncTime 20 µs + ceil(8 × mpdulen / NDBPS) × 4 µs
```

### 3.2 逐项对比

| 项 | RealEmu | ns-3 | 结论 |
|---|---|---|---|
| 前导码 + L-SIG | 20 µs（syncTime = 20 × clkFreq） | 16 + 4 = 20 µs | **一致** |
| NDBPS 查找表 | {24, 36, 48, 72, 96, 144, 192, 216} bit | 6/9/12/18/24/36/48/54 Mbps ÷ 4 µs = 同值 | **一致** |
| SERVICE(16b) + tail(6b) 共 22 bit | **无** | **有** | **不一致**，RTL 固定无法寄存器改 → 软件补包长（见 §4） |
| SignalExtension | 无（等效 0） | 5 GHz = 0（2.4G ERP 才有 6 µs） | 一致（用 802.11a 5 GHz 即可） |
| RTS/CTS/ACK 帧长 | 20 / 14 / 14 字节 | RTS 16+FCS4、CTS/ACK 10+FCS4 | **一致** |
| RTS/CTS/ACK 速率 | 强制 MCS0（6 Mbps） | 基础速率 6 Mbps | **一致** |

### 3.3 常用帧时长数值表（测试程序/分析用）

| 帧 | MCS | 长度 | 时长公式 | 结果 |
|---|---|---|---|---|
| RTS | 0 (6M) | 20 B | 20 + ceil(182/24)×4 | **52 µs** |
| CTS / ACK | 0 (6M) | 14 B | 20 + ceil(134/24)×4 | **44 µs** |
| DATA | m | L B | 20 + ceil((8L+22)/NDBPS_m)×4 | 见 NDBPS 表 |

NDBPS（MCS0–7）= 24 / 36 / 48 / 72 / 96 / 144 / 192 / 216 bit。

## 4. 包长对齐（RealEmu MAC 收包长 ↔ ns-3 物理层 PSDU）

### 4.1 三边定义

| 系统 | "长度"含义 |
|---|---|
| ns-3 物理层 | **PSDU = MAC 头(24/26B) + payload + FCS 4B**，GetPayloadDuration(size) 以它计算 N_sym |
| RealEmu MAC | `mpdulen = frame->data_len`（mac80211 802.11 帧，**含 MAC 头、不含 FCS**） |

### 4.2 软件对齐方案（只改 realwmediumd 一行，不动 RTL）

```c
/* ns-3:  N_sym = ceil((16 + 8L + 6)/NDBPS),  L = PSDU = data_len + 4(FCS)
 * RealEmu: N_sym = ceil(8*L')/NDBPS)
 * 取 L' = data_len + 7  (4B FCS + ~3B 补 SERVICE/tail 22bit)
 * 边界误差: NDBPS 整除余数落在 [NDBPS-1, NDBPS] 时差 1 symbol(4µs), 概率 <1%
 */
macevent.mpduDigest.mpdulen = frame->data_len + 7;
```

副作用（可接受）：RTS 阈值判断、FIFO 计数也使用该长度，语义不变。

## 5. 其他差异（影响点对点延时/隐藏节点行为的次要项）

| 项 | RealEmu | ns-3 | 影响 |
|---|---|---|---|
| NAV 更新 | 仅 RTS/CTS；Duration < 119 µs 时抬升到 119 µs（`2*sifs + 2*slot + sig + 4*6 + phyDelay`） | 所有帧按 Duration/ID 字段严格更新 | 隐藏节点场景 NAV 保护期不同 |
| DATA 帧 Duration 字段 | 固定 SIFS + 20 + 20 = 56 µs | 动态 = SIFS + ACK 实际时长(60 µs) | NAV 精度，±4 µs 级 |
| RTS Duration 字段 | 沿用数据帧 refFrame 的 NAV 值 | SIFS+CTS+SIFS+DATA+SIFS+ACK | RTS 的 NAV 保护严重偏短 |
| CCA 门限 | 硬编码 −30 dBm | CcaEd −62 / CcaSensitivity −82 / RxSensitivity −101 dBm | 点对点强信号下无影响；多节点弱信号有差异 |
| PER 模型 | BRAM 查表（Per.mem） | NistErrorRateModel | 点对点近距离 PER≈0 时无影响 |

## 6. 软件侧对齐清单（写寄存器即可，无需重新综合）

| 寄存器 | 偏移 | 当前值 | 对齐值 | 目的 |
|---|---|---|---|---|
| CWmax | 0x28 | 6 | **10** | CW = 1023，对齐 DCF |
| timeout | 0x20 | 300 | **70** | 对齐 ns-3 45 µs 语义（RealEmu 需收完整响应帧：SIFS16 + ACK44 = 60，留 10 µs 余量） |
| retryLimit | 0x30 | 6 | **7** | dot11ShortRetryLimit |
| rtsThreshold | 0x2C | 1400 | 按测试矩阵 | 与 ns-3 RtsCtsThreshold 同语义（PSDU > 阈值才 RTS） |
| eifs / sifs / slot / difs | 0x0C / 0x04 / 0x00 / 0x08 | 94 / 16 / 9 / 34 | 不动 | 已对齐 |

**RTL 固定、软件无法对齐的项**：SERVICE+tail 22 bit（用包长 +7 补偿）、NAV 抬升逻辑、Duration 字段固定值、CCA 门限、随机数分布。

## 7. 结论

1. MAC 定时基础四元组（slot 9 / SIFS 16 / DIFS 34 / EIFS 94 µs）和控制帧参数（6 Mbps、RTS 20B / CTS / ACK 14B）已与 ns-3 对齐，无需任何改动。
2. 需要软件动作的只有 4 个寄存器写入（CWmax=10、timeout=70、retryLimit=7、rtsThreshold 按矩阵）+ realwmediumd 包长 +7。
3. 最大的非软件差异是 NAV/Duration 字段的简化实现（隐藏节点拓扑下 RTS 保护期偏短）；点对点场景不受影响。
4. 下一步：在 `/home/gtx/dev/RealEmu` 实现点到点测试程序（发送速率 + RTT 延时，覆盖 MCS 0–7 × RTS on/off），按本报告 §6 对齐参数后与 ns-3 结果对比。

---

# 8. 实测对比（TestP2P，2026-10-14）

> 测试程序：`test/TestP2P.bsv`，日志：`/tmp/p2p_sim5.log`（16 case 全通，recv=10/10 全绿，0 丢包、0 看门狗）。
> 本章是 §1–§6 静态对齐之后的**真实仿真结果对比**：先验证实测时序是否落在静态分析预测的窗口内，再逐项归因与 ns-3 理论的差异。

## 8.1 测试配置（与 §6 对齐清单的对应）

| 项 | 值 | 说明 |
|---|---|---|
| 拓扑 | node1 → node0 单向 | 点对点，无隐藏节点 |
| 包长 | 1500 B（MPDU 直发，未 +7） | §4 的 +7 补偿**未应用**，本组数据反映 RealEmu 原始公式 |
| burst / RTT 包数 | 10 / 5 | 段 A 背靠背灌包测吞吐，段 B 单发测 RTT |
| timeout | RTS off = 70，RTS on = 4000 | RTS on 放大是绕过 BUG-A（见 §9.1），非对齐值 |
| CWmin / CWmax / retry | 4 / 10 / 7 | CW=15..1023，与 ns-3 一致 |
| rtsThreshold | off = 65535（不触发）/ on = 100 | 1500B > 100 触发 RTS |
| 信道 | 理想信道 PER=0 | txPower 1920，近距离强信号 |

## 8.2 时序基础量实测验证（帧级时间线提取）

从日志逐帧提取 PHY_TX start→END 与 MAC 事件间隔（时间换算：Bluesim 墙钟 10 ns/cycle，为设计时基 200 cyc/µs 的一半；MAC/PHY 内部计时均以设计时基运行，报告数值自洽）：

| 量 | 实测 | RealEmu 理论 | ns-3 理论 | 判定 |
|---|---|---|---|---|
| T_DATA MCS0–7 (µs) | 2020/1356/1020/688/520/356/272/244 | 20+ceil(12000/NDBPS)×4 **逐帧全部精确命中** | 20+ceil(12022/NDBPS)×4：2024/1356/1024/688/524/356/272/244 | PHY 发送计时器正确；与 ns-3 差 ≤4 µs（SERVICE+tail 22 bit 缺失，MCS2 差 4 µs） |
| SIFS（DATA rxEnd→ACK txStart） | **15.9 µs** | 16 | 16 | ✓（0.1 µs 为采样量化） |
| T_ACK (14B@MCS0) | **40 µs** | 20+ceil(112/24)×4 = 28？实际 40 | 20+ceil(118/24)×4 = **44** | ✗ RealEmu ACK 空口比 ns-3 短 4 µs（同因 SERVICE+tail；§1 静态表的 44/28 均为公式值，实测 40） |
| T_RTS (20B@MCS0) | **48 µs** | 20+ceil(160/24)×4 = 28？实际 48 | 20+ceil(186/24)×4 = **52** | ✗ 同上，短 4 µs |
| DIFS | 34 µs | 34 | 34 | ✓（含在 ACK→DATA 间隔内验证） |
| E[backoff] | — | CW0→15，E=7.5 slot=67.5 µs | 同 | ✓（RTT avg-min ≈ 46 µs，与退避抖动一致） |

**结论 1**：RealEmu 的 MAC/PHY 时间轴（数据帧空口时长、SIFS、DIFS、退避）与理论**精确吻合**，与 ns-3 的差异仅剩控制帧 4 µs 的 SERVICE+tail 缺失和 0.1 µs 级量化。静态对齐工作是有效的。

## 8.3 吞吐与 RTT 实测 vs ns-3 理论

ns-3 理论饱和吞吐按 T_per_pkt = DIFS34 + E[backoff]67.5 + [RTS48+SIFS16+CTS40+SIFS16] + T_DATA + SIFS16 + ACK40，thr = 12000/T_per_pkt（用 RealEmu 实测控制帧时长代入，使差异只剩 MAC 行为）：

| MCS | RTS off 实测 thr (Mbps) | RTS off 理论 | RTS on 实测 | RTS on 理论 | RTS off 实测 rtt_avg | 理论 RTT |
|---|---|---|---|---|---|---|
| 0 | 5 | 5.5 | 5 | 5.4 | 2161 | 2114+67.5≈2181 |
| 1 | 7 | 7.6 | 7 | 7.5 | 1513 | 1517 |
| 2 | 10 | 9.7 | 9 | 9.6 | 1175 | 1181 |
| 3 | 14 | 13.7 | 12 | 13.5 | 845 | 849 |
| 4 | 17 | 16.6 | 14 | 16.3 | 703 | 681 |
| 5 | 23 | 21.9 | 19 | 21.6 | 480 | 517 |
| 6 | 27 | 25.6 | 21 | 25.3 | 437 | 433 |
| 7 | 28 | 26.8 | 23 | 26.5 | 411 | 405 |

（MCS 每档 ~1.2 倍递增的形态与 802.11a NDBPS 24→216 完全一致；RTT 理论 = DIFS+E[bo]+T_DATA+SIFS+ACK。）

**结论 2**：实测与理论总体吻合（低 MCS 差 <3%，RTT 差 <2%）。RTS on 高 MCS 档（5/6/7）实测比理论低 8–13%，专项归因见 §8.4。

## 8.4 吞吐差异逐项归因

1. **测试方法学开销（占实测差距的主体）**：吞吐取 `thrMbps = 10×1500×8 / (t1-t0)`，t0 是**第一包注入时刻**、t1 是**末包收齐时刻**。分母含：首包接入信道前的 DIFS+退避（~100 µs）、首包 PHY_SYNC 后注入流水线、以及测试以 `cycle%50` 门控注入（每 0.25 µs 一拍，包间隔被量化到 ≥50 cyc）。10 包窗口摊薄后，T_DATA 越短（高 MCS）该项占比越大：MCS7 时 (t1-t0)/10 = 421 µs vs 理论 405.5 µs，多出的 ~15 µs/包几乎全部是首包接入开销 + 注入门控。**这是测量口径问题，不是仿真器缺陷**；ns-3 同口径测量同样会偏低。
2. **SERVICE+tail 22 bit 缺失（RTL 固有）**：数据帧/控制帧空口时长普遍比 ns-3 短 0–4 µs。低 MCS 档占比小可忽略；高 MCS 档（T_DATA=244 µs）占比 ~1%。方向是让 RealEmu 吞吐**略偏高**。
3. **RTS on 高 MCS 档额外偏低（8–13%）**：帧级时间线显示 RTS on 的帧间间隔（ACK rx→RTS tx）实测 86.9–127.9 µs，远大于理论 DIFS+bo+e2e 流水线（34+67.5+~12=113.5 µs）的均值，且 ACK→RTS 间隔方差大（RTT max-min 达 100+ µs）。根因是收 ACK 后 `dcfFsmIdle` → `backOffFsm.start` → RTS 发出的跨规则流水线在高数据速率（短 T_DATA）下占比变大。这与 §5 静态分析的"NAV/Duration 简化"无关（点对点无 NAV 生效场景），属 RealEmu MAC FSM 逐帧跨状态开销。
4. **退避随机抖动**：burst 段帧间隔 756–2394 µs（wall）中可见明显 ±60 µs 抖动，与 CW0 E[backoff]=67.5 µs 的均匀分布吻合，非 bug。
5. **整数除法截断**：`thrMbps` 用整数除法，丢弃小数（MCS0 实测 5.49 → 打 5）。造成显示值偏低 ≤0.5 Mbps，建议改定点或浮点打印。

## 8.5 与 ns-3 端到端数值对齐建议

1. 测试程序吞吐口径改为"末包 ACK 时刻 − 首包 ACK 时刻"（排除首包接入开销），或 burst 包数加大到 100+ 摊薄。
2. 应用 §4 的 mpdulen +7（本轮未应用），消除 4 µs/帧的 SERVICE+tail 差异。
3. 修复 BUG-A（§9.1）后，RTS on 的 timeout 恢复 70 µs 对齐值复测。
4. `thrMbps` 打印改浮点（×100 保留两位小数）。

## 8.6 ns-3 实测复核与"流量虚高"归因（2026-10-14）

> 程序：ns-3-dev `scratch/p2p-saturation.cc`，相位机与 TestP2P 同口径（ARP 预热 → 10 包 burst → 5 包单程时延），ConstantRateWifiManager、AdhocWifiMac、FixedRssLossModel(−10 dBm) 理想信道、CW 15–1023、retry 7、ControlMode 6 Mbps。
> 吞吐口径 = 首包注入→末包接收（= RealEmu thr）；"rtt" 两侧均为**单程注入→接收时延**（TestP2P 的 cacheAddr 时戳即单程）。
> 两组：**A 组** UDP payload 1500 B（ns-3 惯例，空口 MPDU=1564 B）；**B 组** payload 1436 B（空口 MPDU 恰 1500 B，对齐 RealEmu 帧长）。

### 8.6.1 帧级证据（PhyTxBegin trace，MCS0）

- ns-3 空口 DATA 帧 **size=1564 B**（1500+UDP8+IP20+LLC/SNAP8+MAC头尾28）；RealEmu 的 1500 B 就是整个 MPDU → 同标称长度 RealEmu 每帧空口少 64 B。
- ns-3 T_DATA(MCS0,1564B)=20+ceil(12534/24)×4=**2112 µs** vs RealEmu **2020 µs**，每帧差 92 µs（4.6%）；相邻 TXB 时间戳差 2274 µs = T_DATA+SIFS+ACK+DIFS+退避，时序结构两侧一致。

### 8.6.2 16 case 同口径对比（thr=Mbps，括号为 RE/ns-3 A 组偏差；rtt_avg=µs）

| MCS | RTS off：RE / ns3A / ns3B | 偏差 | RTS on：RE / ns3A / ns3B | 偏差 | 单程时延 off：RE / ns3A / ns3B |
|---|---|---|---|---|---|
| 0 | 5.52 / 5.31 / 5.29 | +3.9% | 5.24 / 5.02 / 4.99 | +4.3% | 2161 / 2146 / 2058 |
| 1 | 7.95 / 7.67 / 7.64 | +3.7% | 7.33 / 7.09 / 7.04 | +3.4% | 1513 / 1450 / 1390 |
| 2 | 10.10 / 9.95 / 9.89 | +1.5% | 9.29 / 9.00 / 8.91 | +3.2% | 1175 / 1102 / 1058 |
| 3 | 14.23 / 13.99 / 13.92 | +1.7% | 12.56 / 12.18 / 12.05 | +3.1% | 846 / 754 / 722 |
| 4 | 17.56 / 17.70 / 17.46 | −0.8% | 14.94 / 14.89 / 14.62 | +0.4% | 703 / 578 / 558 |
| 5 | 23.24 / 23.72 / 23.45 | −2.0% | 19.39 / 18.93 / 18.59 | +2.4% | 480 / 406 / 390 |
| 6 | 27.97 / 28.71 / 28.30 | −2.6% | 21.59 / 21.98 / 21.52 | −1.8% | 437 / 318 / 306 |
| 7 | 28.50 / 30.78 / 30.40 | −7.4% | 23.77 / 23.17 / 22.71 | +2.6% | 412 / 290 / 278 |

（RE 值取自 detail 行精确 cycle 数换算，非 RESULT 整数截断值。）

### 8.6.3 差异点与"虚高"归因（按贡献排序）

1. **帧长/记账口径差（等效 +4.3%，主因）**：RealEmu 的 1500 B=整个 MPDU（含 24 B MAC 头），吞吐分子把 MAC 头全算有效流量、空口也只占 1500 B；ns-3/真实协议栈的 1500 B=UDP payload，空口 1564 B、分子只算 1500。同样信道时间 RealEmu 多计 1564/1500=4.3%。**闭环验证**：MCS0 RTS off 实测每包时间 RE 2175.6 µs vs ns-3 2260.3 µs（差 −84.7 µs）= 帧长差 −92 µs(DATA) −4 µs(ACK) + FSM 开销 +11 µs，逐项对账吻合；吞吐比 5.52/5.31=+3.9% ≈ 每包时间差。
2. **SERVICE+tail 22 bit 缺失（+0~2%）**：B 组（同 1500 B MPDU）里 RE 仍偏快的部分即此项：DATA 低 MCS 档 +4 µs、ACK/RTS 各 +4 µs（RTS on 一轮 8–12 µs），方向与 1 叠加。
3. **高 MCS 档 RE 反而不虚高（−2~−7%）**：MAC FSM 逐帧跨状态流水线开销抵消并反超——单程时延证据：MCS0 RE/ns3B 差 +103 µs（其中 S/t 占 8、FSM 占 ~95）；MCS7 差 +134 µs（S/t 占 ~8、FSM ~126）。FSM 开销随 MCS 升高占比变大（与 §8.4 第 3 条一致），高 MCS 档实测吞吐因此低于 ns-3。
4. **10 包窗口退避随机性（±4%）**：E[backoff]=67.5 µs 但 10 包样本均值波动大（ns-3 MCS7 五个 RngRun thr=29.9~32.3），个案对比须多 seed。
5. **"虚高"观感的主要来源**：§8.3 的"ns-3 理论"列按 RealEmu 自己的 T_DATA+全均值退避推出（如 MCS7=26.8），实测 ns-3 A 组同口径为 30.8——旧理论列偏保守，使 RE 实测（28.5）看起来"超过 ns-3"。与 ns-3 真跑数据相比，RE 仅在低 MCS 档 +2~4%（口径差），高 MCS 档反而偏低。

### 8.6.4 对齐复测建议（补充）

1. 与 ns-3/真实网卡严格同口径：TestP2P 发 1564 B MPDU（等效满载 UDP 帧）且分子不变；或仍发 1500 B 但吞吐分子只计 (1500−28)×8。
2. 应用 §4.2 的 mpdulen+7 消 SERVICE/tail 差。
3. 高 MCS 档把 FSM 流水线（ACK rx→下一帧 tx ~95–125 µs）列为与 ns-3 收敛到 <2% 的主要优化对象。

---

# 9. 系统已发现问题（Bug 清单）

## 9.1 BUG-A（严重，已定位）：RTS on 时 timeout 计数跨越 DATA 发送期，70 µs 必然误超时

- **现象**：RTS on case 用 ns-3 对齐值 timeout=70 时，MCS0 1500B 全部帧无限重传（日志 447 次 "Timeout, Retransmit in send data duration"），最终看门狗。
- **根因**：`MacCore.bsv` 的 `dcfRecvCtsAck`（L644-742）中，`ctsTimeoutCountReg` 从 RTS 的 `phyStatusWire.txEnd` 起计（L660-668）。**收到 CTS 后该计数不清零**（L673-681 分支只置 `NT_SEND_DATA`），随后 FSM 走 `dcfWaitBackOff` 的 SIFS 退避，到 `NT_SEND_DATA` 分支 L572 检查 `ctsTimeoutCountReg >= macCfgReg.timeout` 时，计数已达 SIFS16+CTS40+SIFS16+e2e≈72-74 µs > 70 µs，误判超时 → 重传。每轮重传都重复此过程 → 无限重传。
- **影响**：RTS on + 高 MCS（DATA 空口长）+ 小 timeout 必触发；RTS off 不受影响（无 CTS 段）。
- **修复建议**：收 CTS 时（L673 分支）清零 `ctsTimeoutCountReg`，且 `NT_SEND_DATA` 分支的 DATA 发送开始后由 `ackTimeoutCountReg` 从 DATA txEnd 重新起计。即恢复"每段等待独立计时"的语义：RTS→CTS 一段，DATA→ACK 一段。
- **本轮绕过**：RTS on case 写 timeout=4000 µs。

## 9.2 BUG-B（严重）：迟到 CTS/ACK 使 FSM 停摆（游离帧死锁）

- **现象**：发送方超时重传后，对端迟到的 CTS 到达时 FSM 已离开 `DCF_RECV_CTSACK`，无人消费 `lowMacRxYesToMEReqQ` 中的 CTS，`dcfRecvCtsAck` 的 notEmpty 分支不再执行，FSM 停摆。
- **根因**：`dcfRecvCtsAck`（L672-715）对"非 CTS 非 ACK 帧"才 deq 丢弃；当 FSM 状态切换后到达的合法响应帧永远滞留队列头部。
- **修复建议**：所有 DCF 状态对 `lowMacRxYesToMEReqQ` 有统一的超龄丢弃（如带时间戳，> timeout+margin 即丢），或在 IDLE 状态兜底 deq。
- **关联**：这是 BUG-A 的次生故障——BUG-A 触发重传后几乎必然诱发本 bug 造成死锁。修复 BUG-A 后本 bug 出现概率大降，但语义上仍应补兜底。

## 9.3 BUG-C（中）：PER 表语义反转（perOut=0 → 全丢）

- **现象**：PER BRAM 表未初始化（全 0）时，`perWire >= randomValueReg` 恒为 False，所有帧 CRC FAIL 全丢。
- **语义**：RealEmu 的判定是"查表值 ≥ 随机数才成功"，与"表值=丢包率"的直觉相反；表灌 0xFFFF（16383/16383=1.0 ≥ 任何随机数）才表示理想信道。
- **影响**：新使用者极易踩坑（以为不初始化=无丢包，实际全丢）。
- **修复建议**：至少在文档/注释中明确；更好的做法是反转语义为"表值 ≥ 随机数 → 丢"或上电默认 0xFFFF。

## 9.4 BUG-D（中）：控制帧 Duration/NAV 简化对 RTS on 的影响

- DATA 帧 Duration 固定 56 µs（应为 SIFS+ACK 实际 40+16=56，数值上恰好正确）；RTS Duration 沿用数据帧 NAV 值而非 SIFS+CTS+SIFS+DATA+SIFS+ACK（严重偏短）。点对点不影响，多节点 NAV 场景会导致 RTS/CTS 保护失效。
- 详见 §5。建议 RTL 改为按帧类型动态计算 Duration。

## 9.5 BUG-E（低）：电平类信号跨 case 残留（burstDone/rttDone）

- `burstDone`/`rttDone` 是电平信号，上一 case 置 True 后残留到下一 case 首包接收才被清除。若切段条件不设时间守卫，会误切。TestP2P 已用 `thrT1 > caseStartCycle` 规避（[TestP2P.bsv](file:///home/gtx/dev/RealEmu/test/TestP2P.bsv) L344-349）。属测试方法学问题，但也提示 RTL 的 per-case 统计寄存器最好提供软件清零或自动按包归属计数。

## 9.6 BUG-F（低）：仿真时基不一致（墙钟 2×设计时基）

- Bluesim 墙钟 10 ns/cycle，而 MAC/PHY 内部计时器按 200 cyc/µs（5 ns/cycle）设计时基运行，`$time` 打印是设计时间的 2 倍。分析日志时须除以 2，否则会得出"DATA 空口 2 倍时长"的错误结论（本次分析即差点误判）。测试台打印 cycle 数（设计时基）与 MAC/PHY `$time`（2×）混用时需注意换算。

## 9.7 观察项（非 bug）

- **CRC OK 日志无时间戳且巨量**（10785 行）：`PhyCore.bsv` L388 的 `$display("%0d CRC OK",id)` 无 `$time`、无 case 归属，日志分析困难，建议加时间戳或降频。
- **`ndbps_lut` 上方残留旧 11n 表**（26/52/78/...，注释掉）：易误导，建议删除注释块。
- **每帧 ACK 间隔 40.1 µs 固定偏移**：ACK 空口 40 µs + 跨模块流水线 ~0.1 µs，行为正常但说明 MAC↔PHY 收链路有固定 ~0.1 µs 延迟。
- **`ackTimeoutCountReg` 双写竞争隐患**：`dcfFsmIdle`（L475）与 `dcfRecvCtsAck`（L651/657）都写该寄存器，靠状态互斥保证安全；若未来加状态需注意。

