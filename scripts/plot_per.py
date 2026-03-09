#!/usr/bin/env python3
import os
import sys
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

def read_per_mem(filename):
    """读取Per.mem文件"""
    with open(filename, 'r') as f:
        lines = f.readlines()
    
    per_values = []
    for line in lines:
        line = line.strip()
        if line:
            per_values.append(int(line, 16))
    
    return per_values

def calculate_snr(sinr_addr):
    """根据SINR地址计算实际的SNR值（dB）"""
    # 从地址计算Q6.5格式的SINR值
    q65_snr = sinr_addr - 160
    # 转换为实际的dB值（右移5位）
    return q65_snr / 32.0

def per_to_success_rate(per_value):
    """将ROM值转换为成功率（ROM值本身就是成功率）"""
    return per_value / 65535.0

def extract_mcs_data(per_values, mcs):
    """提取特定MCS的数据"""
    sinr_samples = 1120
    snr_list = []
    success_rate_list = []
    
    for sinr_addr in range(sinr_samples):
        addr = mcs * sinr_samples + sinr_addr
        if addr < len(per_values):
            per_value = per_values[addr]
            success_rate = per_to_success_rate(per_value)
            snr_db = calculate_snr(sinr_addr)
            snr_list.append(snr_db)
            success_rate_list.append(success_rate)
    
    return np.array(snr_list), np.array(success_rate_list)

def plot_success_rates(per_values, output_dir):
    """绘制不同MCS的成功率曲线"""
    
    num_mcs = 8
    colors = ['#1f77b4', '#ff7f0e', '#2ca02c', '#d62728', 
              '#9467bd', '#8c564b', '#e377c2', '#7f7f7f']
    
    # 创建图形
    plt.figure(figsize=(12, 8))
    
    # 绘制每个MCS的曲线
    for mcs in range(num_mcs):
        snr_array, success_array = extract_mcs_data(per_values, mcs)
        
        plt.plot(snr_array, success_array, 
                marker='o', markersize=2, linewidth=2,
                color=colors[mcs % len(colors)], 
                label=f'MCS-{mcs}', alpha=0.8)
    
    # 图表配置
    plt.title('Packet Success Rate vs SNR for Different MCS\n', fontsize=16, fontweight='bold')
    plt.xlabel('SNR (dB)', fontsize=14, fontweight='bold')
    plt.ylabel('Success Rate', fontsize=14, fontweight='bold')
    
    # 设置坐标轴范围
    plt.xlim(-5, 30)
    plt.ylim(0, 1.05)
    
    # 添加网格
    plt.grid(True, alpha=0.3, linestyle='--', linewidth=0.8)
    
    # 添加图例
    plt.legend(title='MCS Index', loc='lower right', fontsize=11, 
              title_fontsize=12, framealpha=0.9)
    
    # 添加90%成功率参考线
    plt.axhline(y=0.9, color='red', linestyle='--', linewidth=1.5, alpha=0.7, 
               label='90% Success Rate')
    
    plt.tight_layout()
    
    # 保存图片
    output_png = os.path.join(output_dir, "snr_success_rate_plot.png")
    plt.savefig(output_png, dpi=300, bbox_inches='tight', facecolor='white')
    print(f"图表已保存到：{output_png}")
    plt.close()
    
    return output_png

def plot_individual_mcs(per_values, output_dir):
    """为每个MCS绘制单独的图表"""
    num_mcs = 8
    colors = ['#1f77b4', '#ff7f0e', '#2ca02c', '#d62728', 
              '#9467bd', '#8c564b', '#e377c2', '#7f7f7f']
    
    # 创建2x4的子图
    fig, axes = plt.subplots(2, 4, figsize=(16, 8))
    fig.suptitle('Packet Success Rate vs SNR for Each MCS', 
                fontsize=16, fontweight='bold')
    
    for mcs in range(num_mcs):
        row = mcs // 4
        col = mcs % 4
        ax = axes[row, col]
        
        snr_array, success_array = extract_mcs_data(per_values, mcs)
        
        ax.plot(snr_array, success_array, 
               marker='o', markersize=2, linewidth=2,
               color=colors[mcs], alpha=0.8)
        
        ax.set_title(f'MCS-{mcs}', fontsize=12, fontweight='bold')
        ax.set_xlabel('SNR (dB)', fontsize=10)
        ax.set_ylabel('Success Rate', fontsize=10)
        ax.set_xlim(-5, 30)
        ax.set_ylim(0, 1.05)
        ax.grid(True, alpha=0.3, linestyle='--', linewidth=0.5)
        
        # 添加90%参考线
        ax.axhline(y=0.9, color='red', linestyle='--', linewidth=1, alpha=0.5)
    
    plt.tight_layout()
    
    # 保存图片
    output_png = os.path.join(output_dir, "snr_success_rate_individual_mcs.png")
    plt.savefig(output_png, dpi=300, bbox_inches='tight', facecolor='white')
    print(f"各MCS单独图表已保存到：{output_png}")
    plt.close()
    
    return output_png

def print_thresholds(per_values):
    """打印各MCS达到90%成功率所需的SNR阈值"""
    num_mcs = 8
    sinr_samples = 1120
    
    print("\n" + "="*70)
    print("各MCS达到90%成功率所需的SNR阈值")
    print("="*70)
    print(f"{'MCS':<10} {'SNR阈值(dB)':<15} {'成功率':<15} {'说明'}")
    print("-"*70)
    
    for mcs in range(num_mcs):
        threshold_found = False
        for sinr_addr in range(sinr_samples):
            addr = mcs * sinr_samples + sinr_addr
            if addr < len(per_values):
                per_value = per_values[addr]
                success_rate = per_to_success_rate(per_value)
                if success_rate >= 0.9:
                    snr_db = calculate_snr(sinr_addr)
                    print(f"MCS-{mcs:<5}    {snr_db:>10.2f}       {success_rate*100:>10.2f}%       达到90%成功率")
                    threshold_found = True
                    break
        
        if not threshold_found:
            print(f"MCS-{mcs:<5}    {'N/A':>10}       {'N/A':>10}       无法达到90%成功率")
    
    print("="*70)

def main():
    if len(sys.argv) < 2:
        print("用法: python plot_per.py <Per.mem文件路径> [输出目录]")
        print("示例:")
        print("  python plot_per.py /home/emu/dev/RealEmu/mem/Per.mem")
        print("  python plot_per.py /home/emu/dev/RealEmu/mem/Per.mem /home/emu/dev/RealEmu/scripts")
        sys.exit(1)
    
    filename = sys.argv[1]
    
    # 设置输出目录
    if len(sys.argv) >= 3:
        output_dir = sys.argv[2]
    else:
        output_dir = os.path.dirname(os.path.abspath(__file__))
    
    try:
        print("=== 开始处理Per.mem文件 ===")
        per_values = read_per_mem(filename)
        print(f"成功读取 {len(per_values)} 个数据点")
        
        # 打印阈值信息
        print_thresholds(per_values)
        
        # 绘制综合图表
        print("\n=== 开始生成图表 ===")
        plot_success_rates(per_values, output_dir)
        
        # 绘制各MCS单独图表
        plot_individual_mcs(per_values, output_dir)
        
        print("\n✅ 所有图表生成完成！")
        
    except FileNotFoundError:
        print(f"❌ 错误：找不到文件 {filename}")
        sys.exit(1)
    except Exception as e:
        print(f"❌ 错误：{e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    main()
