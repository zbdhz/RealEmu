# Vivado 可选 Tcl 自动流程

完整使用步骤见 [BSV → bitstream 工作流](../../doc/workflow-bsv-to-bitstream.md#6-vivado-生成-bitstream)。
这里集中保存用于 Vivado 2022.2 batch 模式的入口；脚本执行完成后退出该进程。

| 脚本 | Tcl 参数（`-tclargs` 后） | 行为 |
| --- | --- | --- |
| `validate_timing.tcl` | `RUN_DIRECTORY REPO_ROOT ?REFERENCE_DCP?` | 注册已装填的RTL/初始化文件，重置指定工程的综合，重跑实现并验收250MHz时序；jobs固定为8 |
| `generate_bitstream.tcl` | `RUN_DIRECTORY ?JOBS?` | 默认jobs=8，沿用已验收实现生成bitstream；已有有效bit时直接核验并复用 |

`RUN_DIRECTORY` 为包含 `xdma_0_ex/` 的独立模板副本目录，例如
`/home/gtx/project/run261026-tc-nav`；`REPO_ROOT` 为包含 `src/Types.bsv` 的BSV仓库。
这两个脚本不负责复制模板、生成/复制Verilog，也不调用板卡烧写接口。

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

# 上一步退出码为0且出现 REALEMU_TIMING_PASS 后执行。
"$VIVADO_BIN" -mode batch \
  -source "$REALEMU_REPO/backend/vivado/generate_bitstream.tcl" \
  -log generate_bitstream.log -journal generate_bitstream.jou \
  -tclargs "$REALEMU_RUN_DIR" 8
```

结果在 `RUN_DIRECTORY/verification/`，bit在
`RUN_DIRECTORY/xdma_0_ex/xdma_0_ex.runs/impl_1/xilinx_dma_pcie_ep.bit`。
生成入口要求 `timing-result.txt` 通过、检查点未晚于验收记录、综合和实现均未失效；
记录bit与检查点的SHA-256，并检查生成过程中检查点没有变化。Linux环境需有`sha256sum`。

2026-10-26实际运行留档在 `run261026-tc-nav/verification/`，其中的
`validate_timing-used.tcl`、`generate_bitstream.tcl` 是当时使用的副本；本目录为参数化入口。
