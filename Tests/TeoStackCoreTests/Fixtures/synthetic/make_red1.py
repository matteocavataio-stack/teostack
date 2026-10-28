import struct, sys
def entry(tag, data): return struct.pack(">HH", 4 + len(data), tag) + data
def s(t): return t.encode() + b"\0"
S = 0x100
blk1 = bytearray(S)
struct.pack_into(">I", blk1, 0, S); blk1[4:8] = b"RED1"
blk1[0x0a:0x0c] = b"R1"
struct.pack_into(">H", blk1, 0x36, 2048); struct.pack_into(">H", blk1, 0x3a, 1152)
struct.pack_into(">HH", blk1, 0x3e, 25, 1)
blk1[0x43:0x43+32] = b"B001_C002_0101XY.R3D".ljust(32, b"\0")
ents = b"".join([
 entry(0x1000, s("00:00:10:00")), entry(0x1001, s("00:00:10:00")),
 entry(0x1006, s("SN-1")), entry(0x1019, s("RED ONE")), entry(0x101a, s("B001")), entry(0x101b, s("12")),
 entry(0x1023, s("20260312")), entry(0x1024, s("101530")), entry(0x1025, s("30")),
 entry(0x1071, s("RED ONE MYSTERIUM-X")), entry(0x1042, s("a"*120)), entry(0x1043, s("b"*120)), entry(0x1044, s("c"*60)),
 entry(0x403b, struct.pack(">H", 320)),
])
blk2 = bytearray(0x2000)
struct.pack_into(">H", blk2, 0x22, len(ents))
blk2[0x24:0x24+len(ents)] = ents
open(sys.argv[1], "wb").write(bytes(blk1) + bytes(blk2))
