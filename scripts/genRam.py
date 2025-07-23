import math

def generate_bram_duplicate(file_path, num):
    with open(file_path, 'w') as f:
        for _ in range(1024):
            f.write("%x\n" % num)
    print(file_path, "is done !")

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
    generate_bram_duplicate("bram_one.txt", 3)
    generate_bram_log("bram_gainloss_512.txt")