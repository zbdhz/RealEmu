# RealEmu 开发工作流：改码 → 仿真 → 生成 Verilog → 装填 Vivado 工程

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
- **CW 是指数**：`cwMin/cwMax` 写的是 ContWindowExp，窗口 = [0, 2^e−1]。对齐 ns-3 的 CW[15,127] 需写 4/7。
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
- 日志：测试内 `$fwrite` 到 `scripts/bianchi_mcs7.txt`（RX/STAGE 行），$display 到 stdout。设计时基 200 cyc/µs，`$time` 为设计时间。
- 常见编译错：`T0020/T0070/T0080/P0005` 多为 int/Integer/UInt 混用或 pack 后未切位——严格用 `pack(i)` 再切片、`fromInteger/zeroExtend` 显式转换。

## 3. 生成 Verilog

```bash
cd /home/gtx/dev/RealEmu/backend
make verilog
```

做的事：`bsc -verilog -g mkRawEmuCore`（顶层在 `src/BsvTov_simple.bsv`）→ `bluetcl listVlogFiles.tcl` 收集依赖 → 全部 .v 拷到 `backend/verilog/`。

产物（22 个文件，器件 xcvu13p）：

- 18 个 .v：mkEmuCore.v / mkMacBridge.v / mkAxiLiteNodeControlManager.v / mkCwArbiter.v 等
- 3 个 .mem：20lgd.mem / Lg.mem / Per.mem（PER 表，若改过需一并带走）
- bram_one.txt

验证改动是否落位：`grep -c "20'd22" verilog/mkEmuCore.v`（22bit 修复应 32 处）或直接 diff 旧工程对应文件。

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

## 6. Vivado 出 bit（人工/GUI 环节）

```tcl
open_project /home/gtx/project/run261018/xdma_0_ex/xdma_0_ex.xpr
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 40
```

bit 位置：`xdma_0_ex.runs/impl_1/xilinx_dma_pcie_ep.bit`（参考 run261011 耗时约 6 分钟）。

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
Vivado: reset synth_1 → write_bitstream（bit → impl_1/）
```

> 变更记录：2026-10-16 建立本流程（MacCore Fix-B + PhyCore 22bit 修复后的 run261018 工程）。
