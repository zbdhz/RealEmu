def check_illegal_chars(filename):
    with open(filename, "r", encoding="utf-8") as f:
        lines = f.readlines()

    for lineno, line in enumerate(lines, 1):
        for col, ch in enumerate(line):
            if ord(ch) < 32 and ch not in "\n\r\t":  # 控制字符
                print(f"[控制字符] Line {lineno}, Column {col+1}: U+{ord(ch):04X}")
            elif ord(ch) > 127:  # 非 ASCII 字符
                print(f"[非 ASCII] Line {lineno}, Column {col+1}: '{ch}' U+{ord(ch):04X}")

check_illegal_chars("TestChannel.bsv")