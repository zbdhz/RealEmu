#!/usr/bin/env python3
import os
import sys
import pandas as pd
import numpy as np

def csv_to_ram_lookup(csv_file, output_file):
    """将CSV格式的成功率数据转换为RAM查找表格式"""
    # 读取CSV文件
    print(f"读取CSV文件: {csv_file}")
    df = pd.read_csv(csv_file)
    
    # 检查必要的列
    required_columns = ['SINR(dB)', 'MCS0', 'MCS1', 'MCS2', 'MCS3', 'MCS4', 'MCS5', 'MCS6', 'MCS7']
    for col in required_columns:
        if col not in df.columns:
            print(f"错误：CSV文件缺少列 {col}")
            return False
    
    # 按SINR排序
    df.sort_values('SINR(dB)', inplace=True)
    
    # 计算地址映射
    sinr_samples = 1120
    num_mcs = 8
    
    # 生成查找表数据
    lookup_data = []
    
    print(f"生成RAM查找表，共 {sinr_samples} 个SINR点，{num_mcs} 个MCS级别")
    
    for mcs in range(num_mcs):
        mcs_col = f'MCS{mcs}'
        print(f"处理 MCS-{mcs}...")
        
        for sinr_addr in range(sinr_samples):
            # 计算目标SINR值（Q6.5格式转换后）
            target_snr = (sinr_addr - 160) / 32.0
            
            # 智能插值：找到相邻的两个数据点进行线性插值
            # 按SINR排序后的数据
            sorted_snrs = df['SINR(dB)'].values
            sorted_rates = df[mcs_col].values
            
            # 找到插入位置
            idx = np.searchsorted(sorted_snrs, target_snr)
            
            if idx == 0:
                # 低于最小SINR，使用第一个值
                success_rate = sorted_rates[0]
            elif idx >= len(sorted_snrs):
                # 高于最大SINR，使用最后一个值
                success_rate = sorted_rates[-1]
            else:
                # 线性插值
                snr1 = sorted_snrs[idx-1]
                snr2 = sorted_snrs[idx]
                rate1 = sorted_rates[idx-1]
                rate2 = sorted_rates[idx]
                
                # 计算插值权重
                weight = (target_snr - snr1) / (snr2 - snr1)
                success_rate = rate1 + weight * (rate2 - rate1)
            
            # 确保成功率在有效范围内
            success_rate = max(0.0, min(1.0, success_rate))
            
            # 转换为16位十六进制值（0x0000-0xFFFF）
            # 成功率范围：0.0-1.0 -> 0x0000-0xFFFF
            per_value = int(success_rate * 65535)
            hex_value = f"{per_value:04X}"
            lookup_data.append(hex_value)
    
    # 写入输出文件
    with open(output_file, 'w') as f:
        for value in lookup_data:
            f.write(value + '\n')
    
    print(f"成功生成RAM查找表：{output_file}")
    print(f"总数据点：{len(lookup_data)}")
    return True

def main():
    if len(sys.argv) < 3:
        print("用法: python csv_to_ram.py <CSV文件路径> <输出文件路径>")
        print("示例:")
        print("  python csv_to_ram.py /home/emu/dev/RealEmu-test/mcs/mcs-ns3/2025/merged_power_success_rate_smart_fill.csv /home/emu/dev/RealEmu/mem/Per.mem")
        sys.exit(1)
    
    csv_file = sys.argv[1]
    output_file = sys.argv[2]
    
    try:
        if not os.path.exists(csv_file):
            print(f"错误：找不到CSV文件 {csv_file}")
            sys.exit(1)
        
        # 确保输出目录存在
        output_dir = os.path.dirname(output_file)
        if output_dir and not os.path.exists(output_dir):
            os.makedirs(output_dir, exist_ok=True)
        
        print("=== 开始转换CSV到RAM查找表 ===")
        success = csv_to_ram_lookup(csv_file, output_file)
        
        if success:
            print("\n✅ 转换成功！")
            print(f"生成的RAM查找表：{output_file}")
        else:
            print("\n❌ 转换失败！")
            sys.exit(1)
            
    except Exception as e:
        print(f"错误：{e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    main()
