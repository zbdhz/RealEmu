import math

def generate_bram_duplicate(file_path, num):
    with open(file_path, 'w') as f:
        for _ in range(1024):
            f.write("%x\n" % num)
    print(file_path, "is done !")

def generate_bram_sequence_hex(file_path, start=0, end=1023):
    with open(file_path, 'w') as f:
        for i in range(start, end + 1):
            f.write("%x\n" % i)
    print(file_path, "is done !")

def generate_bram_distance_files():
    def int_dist(x1, y1, x2, y2):
        dx = abs(x1 - x2)
        dy = abs(y1 - y2)
        return int(round(math.sqrt(dx * dx + dy * dy))) * 2  # 可改为 *1 或 *10 等

    def write_bram_file(filename, distances):
        with open(filename, 'w') as f:
            for i in range(1024):
                if i < len(distances):
                    f.write("%x\n" % distances[i])
                else:
                    f.write("3ff\n")
    grid_size = 8  # 4x4
    total_nodes = grid_size * grid_size

    for src in range(total_nodes):
        x1, y1 = src % grid_size, src // grid_size
        distances = []
        for dst in range(total_nodes):
            x2, y2 = dst % grid_size, dst // grid_size
            d = int_dist(x1, y1, x2, y2)
            distances.append(d)
        filename = f"bram_{src}.txt"
        write_bram_file(filename, distances)
        print(f"{filename} done!")

# Consider our distance distribution is [0, 65535]
# the range of log is (-∞, 4.82]   
# Set log(0) = 0, than the range is [0, 4.82], We need expand the range   
# GainLoss = 20 log (d), GainLoss is [0, 96.33]
# Set the rom = 512 * GainLoss is [0, 49321]
def generate_bram_log(file_path):
    with open(file_path, 'w') as f:
        f.write("0\n")
        for i in range(1, 1 << 16):
            log_val = math.log10(i)
            hex_val = format(int( (log_val) * 20 * 256), '04X')  # hex_val [0, 65535]
            f.write(hex_val + "\n")
    print(file_path, "is done !")
    

if __name__ == '__main__':
    # generate_bram_duplicate("bram_one.txt", 0)
    # generate_bram_sequence_hex("bram_sequence_1024.txt", 0, 1023)
    # generate_bram_log("bram_gainloss_512.txt")
    generate_bram_distance_files()