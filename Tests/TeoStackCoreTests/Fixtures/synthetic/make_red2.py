import struct, sys
def entry(tag, data): return struct.pack(">HH", 4 + len(data), tag) + data
def s(t): return t.encode() + b"\0"
block = bytearray(0x1000)
struct.pack_into(">I", block, 0, 0x1000)
block[4:8] = b"RED2"
block[7] = ord("2") # keep
block[0x40] = 1
block[0x44:0x48] = b"rdi\x01"
struct.pack_into(">I", block, 0x4c, 4096)
struct.pack_into(">I", block, 0x50, 2160)
struct.pack_into(">3H", block, 0x56, 1000, 0, 24000)  # (a1*0x10000 + a2)/a0 -> 24.0
ents = b"".join([
 entry(0x1000, s("01:02:03:04")),
 entry(0x1001, s("01:02:03:04")),
 entry(0x1005, s("202610281530")),
 entry(0x1006, s("710-0123456")),
 entry(0x1019, s("DSMC2 GEMINI 5K S35")),
 entry(0x101a, s("A012")),
 entry(0x101b, s("3")),
 entry(0x1025, s("7.0.1")),
 entry(0x1036, s("2.4:1")),
 entry(0x1056, s("A012_C003_1028AB_001.R3D")),
 entry(0x106e, s("Zeiss")),
 entry(0x1070, s("Supreme Prime 35mm")),
 entry(0x1071, s("RED EPIC-W")),
 entry(0x107c, s("Operatore Uno")),
 entry(0x1086, s("5K 2.4:1")),
 entry(0x10a1, s("GEMINI 5K S35")),
 entry(0x200d, struct.pack(">f", 5600.0)),
 entry(0x2066, struct.pack(">f", 23.976)),
 entry(0x403b, struct.pack(">H", 800)),
 entry(0x406a, struct.pack(">H", 28)),
 entry(0x406b, struct.pack(">H", 35)),
 entry(0x606c, struct.pack(">i", 2500)),
 entry(0x1042, s("x"*60)),
 entry(0x1043, s("y"*60)),
 entry(0x1044, s("z"*60)),
])
pos = 0x44 + 1*0x18
struct.pack_into(">H", block, pos, len(ents))
block[pos+2:pos+2+len(ents)] = ents
open(sys.argv[1], "wb").write(bytes(block) + b"\0"*4096)
print("dir len", len(ents))
