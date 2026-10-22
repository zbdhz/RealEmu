# 物理层碰撞模型对齐 ns-3 的最小修改方案

> 目标：让 RealEmu 在隐藏节点场景下复现 ns-3 Case 2 的碰撞模式
> （RTS off 吞吐随 N 崩塌 / RTS on 平坦），改动最小化、可回归验证。
> 基准：板上 1018 bit 实测（N=1..15）：off 23.1→17.0 Mbps 缓降；
> ns-3：off 24.8→2.4 Mbps 崩塌。

---

## 1. 根因分析：为什么 RealEmu 不崩塌

当前帧通路：`MacCore → PhyCore(TX) → Channel(算路损) → Arbiter(广播) → 各 PhyCore(RX)`。

### 根因 A：接收状态机"先到者赢"，无双败
- Arbiter（[Arbitration.bsv L121-131](../src/Arbitration.bsv)）把每个 TX 事件**瞬时广播**给
  所有其它节点，帧的"空口时间"只存在于接收端定时器里。
- PhyCore（[PhyCore.bsv L322](../src/PhyCore.bsv)）只在 `PHY_IDLE` 才接受新帧入
  `PHY_SYNC`；正在 `PHY_SYNC/PHY_RX` 时到达的新帧**被静默丢弃**。
- 结果：收端锁定第一帧并大概率 CRC 通过 → 得 ACK；后到的帧虽然丢了，但先到的
  没被毁 → **碰撞最多毁一帧，而 ns-3（默认无 capture）是两帧全毁**。

### 根因 B：CCA 无能量门限，"隐藏"节点实际互相退避
- `updateccaBusyReg`（[PhyCore.bsv L230-241](../src/PhyCore.bsv)）对**任意** rx 事件武装
  `ccaTimerReg`，不看功率；SYNC 门限 `threash = -960`（-30dBm）也极低。
- 数值验证（power=2000 即 62.5dBm，路损 = 20lg(d)）：

| 距离 | 路损 | 接收功率（字段值 / dBm） | > -30dBm 门限？ |
|---|---|---|---|
| 8 | 18dB (576) | 1424 / 44.5dBm | 是（正常通信） |
| 682 | 56.7dB (1814) | 186 / 5.8dBm | 是（P2P 默认距离） |
| 1023 | 60.2dB (1926) | 74 / 2.3dBm | **是！** |

- 即测试脚本里"互距 1023 = 隐藏"的设定**在硬件上不成立**：双方互相把对方帧当成
  介质忙 → MAC 互相退避 → 行为退化成全连通 Bianchi（平坦曲线，实测吻合）。

### 根因 C（次要）：干扰只采样到达瞬间
- `noiseSumReg` 的累加（[PhyCore.bsv L536-579](../src/PhyCore.bsv)）只在事件到达的
  5-cycle 采样窗里取到干扰功率一次，不按重叠时长持续叠加 → 重叠帧对 SINR 影响
  趋近于零。A+B 修掉后此项影响已不大，列为阶段 2。

---

## 2. 修改方案（最小 RTL diff，仅动 PhyCore.bsv）

### 改动 1：接收中打断 = 碰撞双败（核心，~10 行）

正收帧时若又来一个过门限的新帧 → 当前帧判废（CRC 必败），新帧照旧丢弃
（状态机不重同步）→ **两帧全败**，与 ns-3 默认 YansErrorModel 无 capture 行为一致。

```bsv
// (a) L91 附近新增常量（见改动2，一并定义 csThreash）
Int#(12) csThreash = 128;   // 4dBm, 能量检测/碰撞有效门限, 见 §2.2 取值约束

// (b) L118 附近新增寄存器
Reg#(Bool) collideReg <- mkReg(False);

// (c) 新增规则（放在 handlePhyState 之后即可）
// 碰撞标记: 正在收帧时又来一个过 CS 门限的新帧 -> 当前帧判废 (ns-3 双败)
rule markCollision (rxValidReg && (rxPowerReg > csThreash)
                    && (stateReg == PHY_SYNC || stateReg == PHY_RX));
    collideReg <= True;
endrule

// (d) L384 的 CRC 判决加 !collideReg, 并在帧尾清标志:
if (perValidWire) begin
    stateReg <= PHY_IDLE;
    rxEndReg <= True;
    collideReg <= False;                       // <-- 新增: 帧尾清零
    if (perWire >= unpack(randomValueReg) && !collideReg) begin   // <-- 加条件
        crcReg <= True;
    end else begin
        crcReg <= False;
    end
end
```

说明：
- 干扰帧到达 `PHY_SYNC` 期间同样触发（对应 ns-3 前导碰撞）。
- 新帧自身不被接收（状态机忙）→ 发送方等不到 ACK 走超时重传 → 双败闭环
  完全走现有 MAC 超时/重传路径，**MacCore 零改动**。
- ACK 不会被误杀：发送方等 ACK 时已回 `PHY_IDLE`，ACK 正常入 SYNC；若等 ACK
  期间真有重叠帧到达，ns-3 里同样双败。

### 改动 2：CCA/SYNC 加能量门限，制造真隐藏（~6 行）

```bsv
// (a) updateccaBusyReg (L230-241): rx 侧武装 CCA 需过 CS 门限
rule updateccaBusyReg;
    ccaBusyReg <= (ccaTimerReg > 0) || (stateReg == PHY_TX);
    if (psduTimeValidWire && (stateReg == PHY_TX || rxPowerReg > csThreash)) begin
        //          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ 新增门控
        ...（原逻辑不变）
// (b) L322 SYNC 进入门限 threash -> csThreash:
else if (rxValidReg && (rxPowerReg > csThreash)) begin
```

效果：d=1023 的帧（2.3dBm < 4dBm）既不触发 CCA 也不占用接收机 → 隐藏节点对
**完全不互相退避**，与 ns-3 Case 2 的拓扑语义一致；d=8/d=682 一切照旧。

#### csThreash 取值约束（关键！）
必须落在"隐藏对收功率"与"最远正常通信对收功率"之间：

```
74 (d=1023, 2.3dBm)  <  csThreash  <  186 (d=682, 5.8dBm)
推荐 128 (4dBm)
```

注意窗口较窄（由 power=2000、20lg 路损、10bit 距离上限 1023 共同决定）。
若日后改发射功率/距离尺度，需同步重算。长期方案是把 csThreash 寄存器化
（挂到 phyRegSrv，driver 可写），本阶段先静态常量。

### 驱动侧：零改动
`test_hidden_terminal.c` 的 power=2000、拓扑 1023/8 直接复用；
改完后预期 off 组出现崩塌、on 组保持平坦。

---

## 3. 预期效果

| 场景 | 改前 | 改后预期 | ns-3 |
|---|---|---|---|
| hidden off N=8 | 22.4 Mbps（假 Bianchi） | 大幅崩塌（~5-8 Mbps 量级） | 6.27 |
| hidden on N=8 | 21.5 Mbps | 平坦（RTS 碰撞短，快速退避收敛） | 17.67 |
| Bianchi 回归 | — | 基本不变（全 d=8，均 > 门限） | 已对齐 |
| P2P d=682 回归 | — | 不变（186 > 128） | — |

---

## 4. 验证计划

1. **Bluesim 单元验证**：改造 [TestBsvTop_collision.bsv](../test/TestBsvTop_collision.bsv)
   ——两个节点在彼此接收窗口内发包到同一收端，断言两帧都不被收
   （`receivedFrom1/receivedFrom2` 不增长）；错开时间发包，断言均正常接收。
2. **Bianchi 回归**：重跑 `TestBsvTop_bianchi.bsv` 12 档，确认 off/on 与 §8.8
   三轮数据（Fix-B 后）偏差在噪声内。
3. **生成 Verilog + 装填**：按 [workflow-bsv-to-bitstream.md](workflow-bsv-to-bitstream.md)
   从 `xdma_template_0121` 复制新 run（建议 run261021），出 bit 上板。
4. **上板复测**：`sudo ./test_hidden_terminal 1 15 10`，对比 ns-3 Case 2
   （off 24.83/19.50/12.54/6.27/2.42 崩塌；on 19.88→17.46 平坦）。
   注意：当前板上 1018 bit **不含**本改动，必须换新 bit。

---

## 5. 风险与边界

| 风险 | 评估 |
|---|---|
| csThreash 窗口窄（74~186） | 功率/拓扑变更时需重算；建议下阶段寄存器化 |
| 弱帧不再占用接收机 | 反而是收益：d=1023 帧不再阻塞收端 20µs SYNC 窗 |
| 改动1误杀时序相邻帧 | 不会：空口时间由 rxTimer 真实建模，帧间不重叠则收端已回 IDLE |
| ACK/CTS 交互 | 零改动；握手失败统一走既有 timeout 重传（Fix-B 已收敛语义） |
| RTS on 组数值绝对偏差 | 仍受控制帧 MCS0 时长建模影响，趋势对齐即可，绝对值另议 |

## 6. 阶段 2（可选，非本次最小集）

- **持续干扰 SINR**：`handleCycleEnd` 里按重叠时长把干扰功率持续叠加进
  `noiseSumReg`（需在 PhyCore 维护"重叠中干扰功率"寄存器），替代单点采样，
  逼近 ns-3 Yans 的累积干扰能量模型。
- **Capture 效应**：`markCollision` 中若新帧比当前帧弱 ≥10dB 则忽略（不判废），
  对应 ns-3 `WifiPhy::CaptureThreshold` 可选开启。

---

## 附：涉及文件清单

| 文件 | 改动 |
|---|---|
| `src/PhyCore.bsv` | 常量 csThreash、collideReg、markCollision 规则、CRC 判决条件、CCA 门控、SYNC 门限（共 ~16 行净增） |
| 其余（MacCore/Channel/Arbitration/驱动） | **零改动** |
