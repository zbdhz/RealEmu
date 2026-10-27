# 2026-10-27 隐藏节点全量测试 CSV 快照

此目录保存可随代码提交的结果快照；原始构建、日志、图片仍在被忽略的 `output/hidden-1to15-20261027-comparison/`。CSV来自该目录的最终结果，没有重新测量、平滑或修改吞吐数值。

| 文件 | 行数，不含表头 | 内容 |
| --- | ---: | --- |
| [realemu-summary.csv](realemu-summary.csv) | 15 | N=1～15的RealEmu汇总，RTS开关的吞吐、成功收包及入队数中位数/最小/最大值 |
| [realemu-runs.csv](realemu-runs.csv) | 90 | RealEmu逐次结果，含种子、窗口、包数和排空结果 |
| [comparison.csv](comparison.csv) | 30 | 每个N和RTS条件的Real/ns-3吞吐中位数、范围及相对差异 |
| [runs.csv](runs.csv) | 390 | 全部90次Real和300次ns-3记录 |

## 测量口径

- 始终有16个MAC/PHY节点；横轴N=1～15表示隐藏发送者数量，中心接收节点不计入N。
- 每个N分别关闭/开启RTS。RealEmu每个条件使用退避种子12345、23456、34567；ns-3每个条件10次。
- 每次预热20000µs，随后测量100000µs；120ms后停止供包并继续排空。90次Real均有排空PASS。
- 统计采用50 cycles/µs模型时基。默认硬件250 cycles/µs及其实现时序属于不同的验证范围。
- DATA PSDU为1064B，吞吐按1000B有效负载计；数据54Mbps、控制6Mbps。信道采用固定RSS矩阵。
- 接收窗口内按源节点和包标识去重，吞吐 `mbps = unique × 0.08`；汇总使用中位数。
- 每源每80µs提供一次入队机会，输入背压时跳过该次机会。

## 字段与来源

`rts=False/0`表示关闭，`True/1`表示开启。`seed`是平台运行编号，`backoff_seed`是Real实际编译期种子。`warm_us/measure_us`以微秒计；`seconds`是机器执行时间，不是协议模型时间。

`unique`和`duplicates`仅统计100ms接收窗口；`submitted_packets`覆盖包括预热在内的120ms供包阶段，且不等于空口重传次数；`acked_packets_at_stop`为停止供包时的成功ACK完成响应数。不能直接用这些不同时间窗口的计数计算PHY丢包率。

`drained=True`表示该次Real完成了队列排空检查。`log`是原始日志文件名；`reused_from`非空表示保留的旧测量。归档时仅将该字段的机器绝对路径转为仓库相对路径，其他数据字段保持原值。两份汇总CSV与原文件逐字节相同。

N=1/2/4/8/15保留旧30次Real、100次ns-3；其余10个N新增60次Real、200次ns-3。复用前核对了生产源码、ROM、编译参数、测试正文和ns-3库，并完成15档参数识别及四组新旧短窗口对照。

[manifest.json](manifest.json)记录生产源码/ROM、模型、参考程序及动态库校验值，以及四份源CSV和归档CSV的SHA256。归档时已重新检查390个运行键、节点/RTS/种子覆盖、逐次包数到吞吐的换算、全部汇总中位数/范围和相对误差。

最大中位数相对差异约12.61%（N=12、RTS关闭）。最小/最大范围只是观测范围，不是置信区间；排空PASS不代表所有功率、重叠时长或包长都与ns-3等价。详细结果与复现命令见[完整补测报告](../../hidden-node-1to15-experiment-20261027.md)。

## 从仓库快照重画图片

在仓库根目录运行，输出仍放入被忽略的运行目录：

```bash
python3 test/plot_hidden_ns3.py \
  doc/results/hidden-node-1to15-20261027/comparison.csv \
  --output output/hidden-node-from-committed-csv
```

## 后续审查发现

本快照属于问题修复前的受测版本。后续集成测试复现了包尾干扰元数据迟到后漏判、NAV有效期内提前发CTS，以及续跑信任旧检查点指标三个问题，详见[改动审查报告](../../review-hidden-node-changes-20261027.md)。此次归档已独立重算全部CSV数值，因此没有采用独立探针里故意修改的检查点。90次排空PASS仍是实际结果，不能把它解释为这些新边界也已通过。
