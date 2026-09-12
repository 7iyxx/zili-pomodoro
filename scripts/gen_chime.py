# -*- coding: utf-8 -*-
"""
生成番茄钟提示音 assets/sounds/ding.wav
一段柔和的"叮一咚"双音铃声（正弦波 + 指数衰减包络 + 轻微泛音），
纯标准库实现，无需任何第三方依赖。
"""
import math
import os
import struct
import wave

SR = 44100  # 采样率 44.1kHz
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "sounds", "ding.wav")


def tone(freq: float, dur: float, amp: float = 0.6):
    """生成一段带指数衰减包络的乐音采样（含 2、3 次泛音，音色更接近铃声）"""
    n = int(SR * dur)
    out = []
    for i in range(n):
        t = i / SR
        env = math.exp(-4.0 * t / dur)  # 指数衰减包络
        s = (
            math.sin(2 * math.pi * freq * t)
            + 0.35 * math.sin(2 * math.pi * 2 * freq * t)
            + 0.12 * math.sin(2 * math.pi * 3 * freq * t)
        )
        out.append(amp * env * s)
    return out


def silence(dur: float):
    return [0.0] * int(SR * dur)


def fade(xs, ms: float = 8.0):
    """淡入淡出，避免首尾出现"爆音"（click）"""
    k = int(SR * ms / 1000)
    k = min(k, len(xs) // 2)
    for i in range(k):
        xs[i] *= i / k
        xs[-1 - i] *= i / k
    return xs


def main():
    # "叮"(A5, 880Hz) → 短停顿 → "咚"(E5, 659Hz)，总长约 1.3 秒
    samples = tone(880.0, 0.45) + silence(0.06) + tone(659.25, 0.8)
    peak = max(abs(x) for x in samples) or 1.0
    samples = [x / peak * 0.85 for x in samples]  # 归一化，留 15% 余量防削波
    samples = fade(samples)

    data = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, x)) * 32767)) for x in samples)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with wave.open(OUT, "wb") as w:
        w.setnchannels(1)       # 单声道
        w.setsampwidth(2)       # 16bit
        w.setframerate(SR)
        w.writeframes(data)
    print("OK ->", os.path.abspath(OUT), len(data), "bytes")


if __name__ == "__main__":
    main()
