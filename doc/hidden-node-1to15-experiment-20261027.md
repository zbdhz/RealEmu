# 1～15个隐藏发送者的完整补测

本轮延续 `hidden-node-16node-20261026-wcl-sim` 分支的整包最大并发干扰模型，补全横轴1～15个隐藏发送者。中心接收节点不计入N；模型始终实例化16组MAC/PHY，超过N的外围节点不发送业务。

## 实验口径

| 项目 | 设置 |
| --- | --- |
| 发送者N | 1、2、3、4、5、6、7、8、9、10、11、12、13、14、15 |
| RTS/CTS | 每个N分别关闭、开启 |
| RealEmu退避种子 | 12345、23456、34567，每个条件3次 |
| ns-3 | 每个条件10个独立run |
| 单次协议窗口 | 配置完成后预热20ms，再测量100ms；120ms停止供包，继续运行至排空 |
| 结束判据 | 所有节点真实DCF空闲且FIFO为0，持续100µs；必须出现 `TEST_PASS hidden16 drained` |
| 业务 | 每源每80µs有一次供包机会，相邻源错开1µs；输入满时本次机会跳过 |
| 帧 | DATA PSDU 1064B，吞吐按1000B有效负载计算 |
| 速率 | DATA54Mbps，RTS/CTS/ACK6Mbps |
| 退避 | CW15～1023，slot9µs，SIFS16µs，DIFS34µs，EIFS94µs |
| 重试 | 初传加最多6次重传，站级CW失败状态跨包维护 |
| 信道 | 固定RSS矩阵：中心与外围-40dBm，外围相互-110dBm；生产MAC、PHY和Arbiter参与 |
| 统计时基 | 50 cycles/µs；源码硬件默认250 cycles/µs保持原设置 |

结果统计以接收时刻为准，只计20～120ms之间接收端上报、按源和包标识去重后的DATA。预热与排空期间收到的包不并入吞吐；每个条件取三次Real结果的中位数。一包对应0.08Mbps，因而36个包对应2.88Mbps。

实际入队数是整个120ms供包阶段的计数；CSV中的 `submitted_packets` 不能直接与100ms的 `unique` 相除作为PHY丢包率。一个入队包还可能多次空口重传。`acked_packets_at_stop` 是停止供包时收到的成功ACK完成响应数，不是含丢弃在内的全部出队数。

## 新测与保留数据

上一轮N=1、2、4、8、15的30次Real和100次ns-3运行已有完整原始日志及排空PASS。本轮保留这些测量，补跑N=3、5、6、7、9、10、11、12、13、14，即新增60次Real和200次ns-3运行。最终矩阵为90次Real与300次ns-3记录。

复用前逐项核验生产源码、ROM、库、编译宏、随机种子、窗口及ns-3动态库SHA。BSV测试仅扩展参数解析规则；删除该规则后，其余测试正文的SHA与旧测试相同。新模型实际检查了全部15个节点数量，并确认初始业务时刻仍为第15周期。四个短窗口新旧对照得到相同收包数：N=1/off为30、N=1/on为21、N=15/off为4、N=15/on为15。

每条保留记录的 `reused_from` 指向原始日志；空字段表示本轮新测。原有目录不覆盖。具体证据为输出目录的 `reuse-validation.json`，参数和短窗口验证为 `output/hidden-1to15-20261027-argument-check/summary.json`。

本轮测试入口新增固定两位参数 `+nodes01`～`+nodes15`，避免按前缀匹配时把10～15当成1。生产 `src/` 代码沿用上轮版本。本轮没有调整干扰模型、CW、功率或吞吐缩放系数。

## 文件说明

结果目录：`output/hidden-1to15-20261027-comparison/`，由现有Git忽略规则排除。

最后一轮全量测试的四份CSV另有[可提交快照](results/hidden-node-1to15-20261027/README.md)，包括15行Real汇总、90条Real逐次记录、30行对照汇总和390条全部记录。快照附带来源/校验信息；原始构建、日志与图片继续保留在运行产物目录。

| 文件 | 内容 |
| --- | --- |
| `realemu-summary.csv` | 15行，每个发送者数量的RTS off/on吞吐、收包数、入队数中位数与范围 |
| `realemu-runs.csv` | 90条Real逐次记录，含种子、时间窗口、收包数、实际入队数、排空判据和来源 |
| `comparison.csv` | 30行，各N与RTS条件的Real/ns-3中位数、实测范围和相对误差 |
| `runs.csv`、`runs.json` | 全部390条记录，包含300条ns-3和90条Real |
| `summary.json`、`experiment.json` | 构建来源、动态库校验值、参数及汇总元数据 |
| `hidden-node-comparison.png/.svg` | 全部15档与ns-3的吞吐对比；阴影为观测最小/最大值，不是置信区间 |
| `real-*.log`、`ns3-*.log` | 各次完整原始运行日志 |

输出CSV持续记录已完成的运行，完整汇总及图片在所有条件完成后生成。中断后可用相同命令附加 `--resume` 续跑；不同输入会被拒绝，未结束的日志另存为 `*.interrupted-N.log`，不会覆盖功能失败记录。

## 复现

```bash
for seed in 12345 23456 34567; do
  python3 test/run_hidden_node_tests.py --case hidden16-fast --build-only \
    --backoff-seed "$seed" --output "output/full15-model-$seed" --timeout 1800
done

python3 test/compare_hidden_ns3.py \
  --bsv output/full15-model-12345/hidden16-fast/simulate \
  --bsv output/full15-model-23456/hidden16-fast/simulate \
  --bsv output/full15-model-34567/hidden16-fast/simulate \
  --ns3-root /home/gtx/dev/ns-3-dev-git \
  --output output/full15-comparison --long --jobs 30 --timeout 3600

python3 test/plot_hidden_ns3.py output/full15-comparison/comparison.csv
```

默认遍历1～15，也可以用 `--senders` 指定子集。以上命令全部新测；本轮实际运行另加 `--reuse-from output/hidden-cw-20261027-comparison`，并经过前述一致性核验。

本实验验证受控固定RSS场景的MAC/PHY吞吐。整包峰值近似仍不包含ns-3按重叠持续时间计算BER的全部语义；有限次数的观测范围不能替代统计等价性证明。此轮不涉及新RTL实现时序、driver或板卡测试。

## 完成结果

90次Real与300次ns-3记录全部齐全；新增60次Real全部完成测量并排空，无TEST_FAIL。生产源码、ROM与上一轮保持相同；15个节点参数及四个新旧短窗口条件验证通过。

| 隐藏发送者N | Real off Mbps | Real on Mbps | ns-3 off Mbps | ns-3 on Mbps | off差异 | on差异 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 23.36 | 16.88 | 23.40 | 17.00 | -0.17% | -0.71% |
| 2 | 19.28 | 15.84 | 20.00 | 16.28 | -3.60% | -2.70% |
| 3 | 16.32 | 15.60 | 16.32 | 15.72 | +0.00% | -0.76% |
| 4 | 13.44 | 14.80 | 13.92 | 14.84 | -3.45% | -0.27% |
| 5 | 11.68 | 13.92 | 11.44 | 14.68 | +2.10% | -5.18% |
| 6 | 10.40 | 14.16 | 10.16 | 14.24 | +2.36% | -0.56% |
| 7 | 8.64 | 13.52 | 8.40 | 13.80 | +2.86% | -2.03% |
| 8 | 7.20 | 13.36 | 7.28 | 13.52 | -1.10% | -1.18% |
| 9 | 6.48 | 13.44 | 6.32 | 12.96 | +2.53% | +3.70% |
| 10 | 5.28 | 13.36 | 5.72 | 12.92 | -7.69% | +3.41% |
| 11 | 4.80 | 12.64 | 5.12 | 12.44 | -6.25% | +1.61% |
| 12 | 5.36 | 12.80 | 4.76 | 12.64 | +12.61% | +1.27% |
| 13 | 4.08 | 12.56 | 4.28 | 12.32 | -4.67% | +1.95% |
| 14 | 3.36 | 12.32 | 3.84 | 12.32 | -12.50% | +0.00% |
| 15 | 2.88 | 12.24 | 3.20 | 12.28 | -10.00% | -0.33% |

完整图片为`realemu-throughput.png/.svg`和`hidden-node-comparison.png/.svg`，完整性核验为`acceptance.json`，下载包为`hidden-node-1to15-results.zip`。原始逐次CSV保留三个种子的包数与窗口，表中范围不用于宣称统计等价。

完整扫描中，最大中位数相对差异为N=12、RTS off的+12.61%（RealEmu 5.36 / ns-3 4.76 Mbps）；N=14/off为-12.50%（3.36 / 3.84Mbps）。RTS on的最大中位数差异约5.18%，出现在N=5。23/30个条件的中位数绝对差异小于4%。

RTS off在N=12出现局部抬升，三次唯一收包数为60/70/67；没有对曲线做单调化处理。100ms窗口内接收样本有限，该抬升及偏差的稳定性需要更长窗口或更多种子才能进一步判断，当前数据不能作为全面统计等价的证明。
