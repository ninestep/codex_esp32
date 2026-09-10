import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "power_export", Path(__file__).resolve().parents[2] / "export-power-log.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

row = "0123456789abcdef,30000,1,3,0,1,90,4190,1,5000,3,56,51,16,139,106\n"
checksum = 2166136261
for byte in row.encode():
    checksum = ((checksum ^ byte) * 16777619) & 0xffffffff
prefix = [b"I (1) boot: hello\n", b"POWERLOG_BEGIN v=1\r\n", (module.HEADER + "\r\n").encode()]
ending = f"POWERLOG_END rows=1 fnv1a={checksum:08x}\r\n".encode()
assert module.collect(prefix + [row.encode(), b"I (2) task: running\n", ending]) == module.HEADER + "\n" + row

for lines in [
    prefix + [ending],  # 丢行
    prefix + [row.replace("4190", "4191").encode(), ending],  # 数据损坏
    prefix + [row.encode()],  # 中断传输
    prefix + [b"POWERLOG_ERROR read_failed\n"],
    prefix + [b"0123456789abcdef,300\n", ending],  # 断电留下的半行
]:
    try:
        module.collect(lines)
    except (RuntimeError, TimeoutError):
        pass
    else:
        raise AssertionError("incomplete export accepted")
print("test_power_log_export: PASS")
