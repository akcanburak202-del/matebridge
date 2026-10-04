# tone.py OUT.wav — 320 s stereo 48 kHz melody (six notes, 250 ms each) for the audio path during T-127 runs.
import math, struct, sys, wave
sr = 48000; notes = [261.6, 329.6, 392.0, 523.3, 392.0, 329.6]; buf = bytearray()
for i in range(sr * 320):
    v = int(6000 * math.sin(2 * math.pi * notes[(i // (sr // 4)) % len(notes)] * i / sr)); buf += struct.pack('<hh', v, v)
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr); w.writeframes(bytes(buf)); w.close()
