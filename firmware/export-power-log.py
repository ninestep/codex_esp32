#!/usr/bin/env python3
"""从设备导出离线电量 CSV；使用 ESP-IDF Python 环境中的 pyserial。"""

import argparse
import csv
import glob
import io
from pathlib import Path
import re
import time


HEADER = "boot_id,uptime_ms,reset_reason,mode,read_error,battery_present,battery_percent,battery_mv,charging,vbus_mv,stage,status0,status1,irq0,irq1,irq2"


def collect(lines):
    started = False
    header_seen = False
    rows = []
    checksum = 2166136261
    for raw in lines:
        line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
        if "POWERLOG_ERROR" in line:
            raise RuntimeError(line)
        if line == "POWERLOG_BEGIN v=1":
            if started:
                raise RuntimeError("设备重新开始导出，当前传输不完整")
            started = True
            continue
        if not started:
            continue
        if line == HEADER:
            header_seen = True
            continue
        end = re.fullmatch(r"POWERLOG_END rows=(\d+) fnv1a=([0-9a-f]{8})", line)
        if end:
            if not header_seen or len(rows) != int(end[1]) or checksum != int(end[2], 16):
                raise RuntimeError("导出行数或校验值不匹配，请重试；不保存不完整 CSV")
            return HEADER + "\n" + "".join(rows)
        if re.match(r"^[0-9a-f]{16},", line):
            fields = next(csv.reader([line]))
            if len(fields) != 16 or any(not re.fullmatch(r"-?\d+", field) for field in fields[1:]):
                raise RuntimeError("日志包含损坏或不完整记录；保留设备原数据，未输出 CSV")
            row = line + "\n"
            for byte in row.encode("ascii"):
                checksum = ((checksum ^ byte) * 16777619) & 0xffffffff
            rows.append(row)
    raise TimeoutError("未收到完整导出结束标记；确认设备已烧录离线日志固件")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="新的 CSV 文件路径，不覆盖已有文件")
    parser.add_argument("--port", help="例如 /dev/cu.usbmodem1101；仅一个设备时自动发现")
    parser.add_argument("--timeout", type=float, default=600, help="总超时秒数，默认 600")
    args = parser.parse_args()
    raw_path = args.output.with_suffix(".raw.log")
    if args.output.exists() or raw_path.exists():
        parser.error("输出文件已存在，请换一个文件名")
    ports = glob.glob("/dev/cu.usbmodem*") if args.port is None else [args.port]
    if len(ports) != 1:
        parser.error("未发现唯一设备，请通过 --port 指定串口")
    if args.timeout <= 30:
        parser.error("超时应大于 30 秒，设备在现有采样周期处理导出命令")
    import serial

    with raw_path.open("xb") as capture, serial.Serial(port=None, baudrate=115200, timeout=1) as device:
        device.dtr = False
        device.rts = False
        device.port = ports[0]
        device.open()
        # USB 打开可能触发复位；等启动完成后发送，避免命令被 ROM 启动阶段吞掉。
        send_at = time.monotonic() + 10
        deadline = time.monotonic() + args.timeout

        def lines():
            pending = b""
            sent = False
            while time.monotonic() < deadline:
                if not sent and time.monotonic() >= send_at:
                    device.write(b"\npowerlog dump\n")
                    device.flush()
                    sent = True
                chunk = device.read_until(b"\n")
                capture.write(chunk)
                pending += chunk
                if pending.endswith(b"\n"):
                    yield pending
                    pending = b""
                if len(pending) > 4096:
                    raise RuntimeError("串口行过长或传输损坏")

        content = collect(lines())
    with args.output.open("x", encoding="ascii", newline="") as output:
        output.write(content)
    print(f"已校验并保存 {len(list(csv.reader(io.StringIO(content)))) - 1} 条记录：{args.output}")


if __name__ == "__main__":
    main()
