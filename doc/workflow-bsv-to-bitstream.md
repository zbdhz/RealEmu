# RealEmu 开发工作流：改码 → 仿真 → Verilog → Vivado → bitstream

> 适用环境：`/home/gtx/dev/RealEmu`（BSV 源码工程）→ `/home/gtx/project/runXXXX/`（Vivado 工程链）。
> BSC 工具链：`/home/gtx/env/bsc-2025.01.1-ubuntu-22.04/bin`（每次开终端需手动 export，make 里 export 的 PATH 不会带进运行环境）。

## 0. 环境准备（每个新终端一次）

```bash
export PATH=/home/gtx/env/bsc-2025.01.1-ubuntu-22.04/bin:$PATH
```

## 1. 修改 Bluespec（BSV）源码

源码位置：`src/`（设计本体）与 `test/`（仿真测试）。

| 目录 | 内容 |
|---|---|
| `src/MacCore.bsv` | MAC 层 DCF 状态机（发送/接收/重传/NAV） |
| `src/PhyCore.bsv` | PHY 层（帧时长计算、CCA、PER） |
| `src/CsmaUtils.bsv` | 退避/CW 常量、控制帧构造（RTS/CTS/ACK） |
| `src/BsvTov_simple.bsv` | 顶层 `mkRawEmuCore`（16 节点汇聚） |
| `src/Types.bsv` | MAC 配置寄存器默认值、AXI-Lite 寄存器偏移 |
| `test/TestBsvTop_bianchi.bsv` | Bianchi 多节点吞吐测试（MCS7、RTS 开关） |
| `test/TestP2P.bsv` | 点对点测试（AXI-Lite 配置写法的模板参考） |

改动要点：

- **寄存器默认值**：`src/Types.bsv` 的 `getDefaultMacCfg`（如 timeout: 300）。测试里通过 AXI-Lite 覆写（`mac_timeout_off='h020`、`mac_cw_min_off='h024`、`mac_cw_max_off='h028`、`mac_rts_thresh_off='h02C`、`mac_retry_limit_off='h030`，基址 `node_base_addr='h0010_0000 + node_per_node*n`）。
- **CW 是指数**：`cwMin/cwMax` 写的是 ContWindowExp，窗口 = [0, 2^e−1]。CW[15,1023] 写 4/10；若目标上限为127则写4/7。实际对照参数以实验配置为准。
- **控制帧速率**：`CsmaUtils.bsv` 的 setRtsFrame/setCtsFrame/setAckFrame 目前硬编码 `mcs=0`（已知不等价项，见 doc/ns3-param-alignment-80211a.md §8.8）。
- **G0010 冲突**：发包必须收敛到单一规则（controller），不要另开规则调 `core.tx.put`；接收统计规则用 `(* descending_urgency = "receive, controller" *)` 消解。

改完先在 test 里跑对应测试验证行为，再进下一步。

## 2. 跑仿真（Bluesim）

测试 Makefile 在 `test/Makefile`，当前编译目标由文件顶部注释块切换（编辑 `TESTFILE`/`TOPMODULE` 两行，如切到 bianchi）：

```makefile
TESTFILE ?= TestBsvTop_bianchi.bsv
TOPMODULE ?= mkTestRawEmuCore_bianchi
```

然后：

```bash
cd /home/gtx/dev/RealEmu/test
make compile        # bsc -elab -sim（生成 bo/baar，会先跑 genRam.py 生成 bram_*.txt 并拷 .mem）
make simulate       # 链接 + 在 build/ 里执行 mkTestRawEmuCore_bianchi.sh
```

说明：

- 长仿真建议 `make simulate > /tmp/xxx.log 2>&1 &` 后台跑，`tail -f` 观察；跑前确认旧进程已结束（`ps aux | grep mkTest` ），避免两个仿真同时写同一个日志。
- **Bluesim 速度约 4 ms 设计时间/分钟墙钟**。Bianchi 12 档 × 20 ms = 240 ms 设计时间 ≈ 1 小时量级，安排统计窗时先估算。
- 时基：`src/Types.bsv` 的 `REALEMU_US_CYCLES` 是 MAC/PHY 的共同 cycles/µs，当前默认 **250**，对应 XDMA `user_clk=250 MHz`。测试用 `cycle / US_CYCLES` 换算模型 µs；Bluesim 默认一个周期为 10 个时间单位，日志 `$time` 后虽有历史 `ns` 后缀，也不能直接当作模型空口时间。旧 200 cycles/µs 是历史配置。
- 自动化回归：在仓库根目录运行 `python3 test/run_tc_tests.py --output output/tc-独立目录名` 和 `python3 test/run_deadlock_tests.py --output output/deadlock-独立目录名`。每次使用新目录，源码快照、编译命令、初始化文件、日志及 JSON 结果均留在已忽略的 `output/`。测试编译时可以显式 `-D REALEMU_US_CYCLES=200`，综合时必须与实际时钟一致。
- Bianchi 等旧统计测试仍需独立验证统计窗口与阶段切换；本次时间单位转换不代表其吞吐统计已对齐 ns-3。
- 常见编译错：`T0020/T0070/T0080/P0005` 多为 int/Integer/UInt 混用或 pack 后未切位——严格用 `pack(i)` 再切片、`fromInteger/zeroExtend` 显式转换。

## 3. 生成 Verilog

```bash
cd /home/gtx/dev/RealEmu/backend
make verilog
```

做的事：`bsc -verilog -g mkRawEmuCore`（顶层在 `src/BsvTov_simple.bsv`）→ `bluetcl listVlogFiles.tcl` 收集依赖 → 全部 .v 拷到 `backend/verilog/`。

产物通常为 22 个文件；BSV 导出文件本身不指定 FPGA 器件，器件以实际 Vivado 工程为准。当前 `xdma_template_0121` / `run261026-tc` 工程为 **xcu280-fsvh2892-2L-e**，不能沿用旧文档的 xcvu13p 标注：

- 18 个 .v：mkEmuCore.v / mkMacBridge.v / mkAxiLiteNodeControlManager.v / mkCwArbiter.v 等
- 3 个 .mem：20lgd.mem / Lg.mem / Per.mem（PER 表，若改过需一并带走）
- bram_one.txt

验证改动是否落位：检查BSC导出日志及产物清单，核对RTL和初始化文件来自同一批构建，再与目标工程副本逐文件比对。流水改动可能改变生成代码形式，不以固定Verilog字符串出现次数代替功能验证。

## 4. 复制模板工程（runXXXX）

**真实模板是 `/home/gtx/project/xdma_template_0121/`**（bash 日志确认：run0303/run0304 均由它复制；imports 自 2026-01-21 起为当前版本，与 run261011 一致）。不要从旧 run（如 run1013/run1113）复制——那些是历史工程，imports 版本旧。

```bash
cd /home/gtx/project
cp -r xdma_template_0121 run261018          # 命名惯例 run + YYMMDD
```

结构（注意多一层 `xdma_0_ex/`，xpr 在这一层）：

```
run261018/
└── xdma_0_ex/
    ├── xdma_0_ex.xpr                # Vivado 工程
    ├── imports/                     # XDMA 顶层（xdma_app.v 等，勿动）
    ├── xdma_0_ex.srcs/sources_1/new/   # ← BSV 生成 RTL 的落位目录
    ├── xdma_0_ex.runs/              # 综合实现结果（bit 在 impl_1/）
    └── xdma_0_ex.cache/ .gen/ ...
```

## 5. 装填 Verilog 进工程

```bash
cp /home/gtx/dev/RealEmu/backend/verilog/*.v \
   /home/gtx/dev/RealEmu/backend/verilog/*.mem \
   /home/gtx/dev/RealEmu/backend/verilog/bram_one.txt \
   /home/gtx/project/run261018/xdma_0_ex/xdma_0_ex.srcs/sources_1/new/
```

装填后校验：

```bash
cd /home/gtx/project/run261018/xdma_0_ex/xdma_0_ex.srcs/sources_1/new
for f in $(ls /home/gtx/dev/RealEmu/backend/verilog/); do
    diff -q "/home/gtx/dev/RealEmu/backend/verilog/$f" "$f" || echo "MISMATCH $f"
done
```

注意：模板 xpr（2026-01-21）早于 `mkAxiLiteNodeControlManager.v` 加入的时间，若 Vivado 打开后 synth 报 missing file，在 GUI 里把该文件 add sources 即可（run261011 即如此使用）。

## 6. Vivado 生成 bitstream

完成第4、5步后，可以选择GUI或Tcl batch方式。两种方式都先检查实际实现时序，再生成bitstream。

### 6.1 方式A：GUI操作

1. 打开独立模板副本中的 `xdma_0_ex/xdma_0_ex.xpr`，检查器件、源文件与初始化文件已正确注册。
2. 执行Run Synthesis、Run Implementation，检查实现和布线是否完成。
3. 在实现设计中检查Timing Summary、DRC及布线报告；当前目标为 `user_clk=4ns/250MHz`，setup/hold均应满足。
4. 时序验收后执行Generate Bitstream。

### 6.2 方式B：可选的Tcl自动流程

脚本集中在 [backend/vivado/](../backend/vivado/README.md)。这是2026-10-26实际使用的“实现及验收→沿用验收实现生成bit”流程的参数化入口；模板复制和Verilog装填仍按第4、5步完成。

| 脚本 | `-tclargs`参数 | 执行内容 |
| --- | --- | --- |
| [validate_timing.tcl](../backend/vivado/validate_timing.tcl) | `RUN_DIRECTORY REPO_ROOT [REFERENCE_DCP]` | 重置指定副本的综合，重新综合、布局布线及布线后物理优化，检查时基和时序 |
| [generate_bitstream.tcl](../backend/vivado/generate_bitstream.tcl) | `RUN_DIRECTORY [JOBS]` | 沿用已验收实现生成bit；有效bit已完成时核验并复用；默认jobs=8 |

`RUN_DIRECTORY`是包含 `xdma_0_ex/` 的运行目录，不是 `.xpr` 文件；`REPO_ROOT`是包含 `src/Types.bsv` 的BSV仓库。脚本用于Vivado 2022.2的batch入口，结束时退出该进程，均不操作板卡。

**第一步：实现和时序验收。** 使用已经装填RTL/初始化文件的专用模板副本，例如 `run261026-next`；该入口会重跑此副本的综合和实现。

```bash
REALEMU_REPO=/home/gtx/dev/RealEmu
REALEMU_RUN_DIR=/home/gtx/project/run261026-next
VIVADO_BIN=/tools/Xilinx/Vivado/2022.2/bin/vivado

mkdir -p "$REALEMU_RUN_DIR/verification"
cd "$REALEMU_RUN_DIR/verification"

"$VIVADO_BIN" -mode batch \
  -source "$REALEMU_REPO/backend/vivado/validate_timing.tcl" \
  -log validate_timing.log -journal validate_timing.jou \
  -tclargs "$REALEMU_RUN_DIR" "$REALEMU_REPO"
```

脚本重新注册导出的 `.v`、`.mem` 和 `bram_one.txt`，保持工程的板卡/IP约束；检查 `REALEMU_US_CYCLES` 与XDMA MHz一致。它使用8个jobs，要求 `user_clk=4ns`、setup/hold非负，保存时序、资源、DRC与布线报告。**退出码为0且日志出现 `REALEMU_TIMING_PASS` 才进入下一步。** 报告中的普通告警仍需审阅，逻辑仿真不能代替实现时序验收。

可选第三个参数为已有实现的参考DCP，用于尝试增量复用物理位置：

```bash
REALEMU_REFERENCE_DCP=/home/gtx/project/previous-run/xdma_0_ex/xdma_0_ex.runs/impl_1/xilinx_dma_pcie_ep_postroute_physopt.dcp

"$VIVADO_BIN" -mode batch \
  -source "$REALEMU_REPO/backend/vivado/validate_timing.tcl" \
  -log validate_timing.log -journal validate_timing.jou \
  -tclargs "$REALEMU_RUN_DIR" "$REALEMU_REPO" "$REALEMU_REFERENCE_DCP"
```

匹配率不足时Vivado可自动回退完整布局，以运行日志为准；仍须对本次RTL重新综合、布线和验收。

**第二步：沿用验收实现生成bitstream。** 继续使用上面的环境变量：

```bash
"$VIVADO_BIN" -mode batch \
  -source "$REALEMU_REPO/backend/vivado/generate_bitstream.tcl" \
  -log generate_bitstream.log -journal generate_bitstream.jou \
  -tclargs "$REALEMU_RUN_DIR" 8
```

该入口要求 `verification/timing-result.txt` 为通过值、布线后检查点存在且未晚于验收记录、synth/impl均未失效。它不调用 `reset_run`；遇到失效实现就报错，由第一步重新验收。成功标记为 `REALEMU_BITSTREAM_PASS`，同时记录bit与检查点的SHA-256，并核对生成过程中检查点没有变化。当前Linux环境需有`sha256sum`。

若实现已验收，只需设置 `REALEMU_RUN_DIR` 指向该副本后执行第二步；不必为了生成bit再次重跑第一步。完整实现通常为小时量级，沿用检查点生成bit为分钟量级，实际耗时取决于设计和主机资源。

### 6.3 产物和实际运行记录

| 位置（相对`RUN_DIRECTORY`） | 内容 |
| --- | --- |
| `verification/validate_timing.log`、`.jou` | 实现验收的Vivado日志与journal |
| `verification/timing-result.txt`、`timing_summary.rpt` | 时基、setup/hold摘要及详细时序 |
| `verification/utilization.rpt`、`route_status.rpt`、`drc.rpt` | 资源、布线与DRC |
| `verification/generate_bitstream.log`、`.jou`、`bitstream-result.txt` | bit生成日志、路径、大小、哈希与复用情况 |
| `xdma_0_ex/xdma_0_ex.runs/impl_1/xilinx_dma_pcie_ep_postroute_physopt.dcp` | 布线后物理优化检查点 |
| `xdma_0_ex/xdma_0_ex.runs/impl_1/xilinx_dma_pcie_ep.bit` | 最终bitstream |

本次实际工程为 `/home/gtx/project/run261026-tc-nav/xdma_0_ex/xdma_0_ex.xpr`，器件为 **xcu280-fsvh2892-2L-e**；最终bit位于该工程的 `xdma_0_ex.runs/impl_1/`。当时执行的脚本副本及原始记录保存在 `run261026-tc-nav/verification/`，不随仓库脚本整理而覆盖。

版本管理只收录 `backend/vivado/*.tcl`、README和工作流说明；生成的Verilog、日志、DCP和bit继续放在构建/运行目录。

## 附：完整流水线一览

```
改 src/*.bsv / test/*.bsv
   │  cd test && make compile && make simulate      （行为验证，Bluesim ~4ms 设计时/min）
   ▼
cd backend && make verilog                          （bsc -verilog + bluetcl，产 22 文件）
   ▼
cd /home/gtx/project && cp -r xdma_template_0121 runYYMMDD
   ▼
cp backend/verilog/* runYYMMDD/xdma_0_ex/xdma_0_ex.srcs/sources_1/new/
   ▼
Vivado GUI，或可选Tcl：validate_timing.tcl → generate_bitstream.tcl
   │  verification/ 保存报告与日志；bit → xdma_0_ex.runs/impl_1/
   ▼
按板卡操作流程烧写（独立步骤；上述Tcl不执行烧写）
```

> 变更记录：2026-10-16 建立本流程（MacCore Fix-B + PhyCore 22bit 修复后的 run261018 工程）。
>
> 2026-10-26：补充可选Tcl batch流程，脚本集中到`backend/vivado/`；区分重跑实现验收与复用检查点生成bit，记录参数、成功标记和产物位置。
