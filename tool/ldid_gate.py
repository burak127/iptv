"""Fail the iOS build if AltStore's ldid would abort on any binary.

AltServer re-signs sideloaded apps with a vendored old `ldid` whose
Allocate() hard-asserts `end >= size - 0x10`: with a code signature
present, every Mach-O slice needs

    0 <= LC_CODE_SIGNATURE.dataoff - (stroff + strsize) <= 0x10

This is a byte-for-byte replica of that check. If ANY binary fails, exit
non-zero and name it, so a doomed .ipa never reaches anyone's phone.

Usage: python3 tool/ldid_gate.py build/ios/iphoneos/Runner.app
"""
import os
import struct
import sys

APP = sys.argv[1] if len(sys.argv) > 1 else "build/ios/iphoneos/Runner.app"
LC_SYMTAB, LC_CODE_SIGNATURE = 0x2, 0x1d
MAGICS = (0xcafebabe, 0xbebafeca, 0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe)


def slices(data):
    magic = struct.unpack(">I", data[:4])[0]
    if magic in (0xcafebabe, 0xbebafeca):
        be = magic == 0xcafebabe
        n = struct.unpack((">" if be else "<") + "I", data[4:8])[0]
        off, out = 8, []
        for _ in range(n):
            o, s = struct.unpack((">" if be else "<") + "II", data[off+8:off+16])
            out.append((o, s)); off += 20
        return out
    return [(0, len(data))]


bad, checked = [], 0
for root, dirs, files in os.walk(APP):
    for fn in files:
        fp = os.path.join(root, fn)
        with open(fp, "rb") as fh:
            head = fh.read(4)
        if len(head) < 4 or struct.unpack(">I", head)[0] not in MAGICS:
            continue
        data = open(fp, "rb").read()
        for so, ssize in slices(data):
            m = struct.unpack(">I", data[so:so+4])[0]
            if m in (0xfeedface, 0xcefaedfe): is64, le = False, m == 0xcefaedfe
            elif m in (0xfeedfacf, 0xcffaedfe): is64, le = True, m == 0xcffaedfe
            else: continue
            e = "<" if le else ">"
            ncmds = struct.unpack(e+"I", data[so+16:so+20])[0]
            off = so + (32 if is64 else 28)
            stroff = strsize = sig = None
            for _ in range(ncmds):
                cmd, csz = struct.unpack(e+"II", data[off:off+8])
                if cmd == LC_SYMTAB:
                    _, _, stroff, strsize = struct.unpack(e+"IIII", data[off+8:off+24])
                elif cmd == LC_CODE_SIGNATURE:
                    sig = struct.unpack(e+"I", data[off+8:off+12])[0]
                off += csz
            rel = os.path.relpath(fp, APP)
            checked += 1
            if sig is None:
                bad.append(f"{rel}: NO code signature (re-sign step failed?)")
                continue
            if stroff is None or (stroff == 0 and strsize == 0):
                print(f"  ok (no symtab)      {rel}")
                continue
            end, size = stroff + strsize, sig
            gap = size - end
            if end <= size and end >= size - 0x10:
                print(f"  ok (gap {gap:>3})       {rel}")
            else:
                bad.append(f"{rel}: gap {gap} bytes — ldid WILL abort on this file")

print(f"\nchecked {checked} Mach-O slices")
if checked == 0:
    print(f"GATE FAILED — no Mach-O binaries found under {APP}")
    sys.exit(1)
if bad:
    print("GATE FAILED — these binaries would trip AltServer's ldid assert:")
    for b in bad: print("   " + b)
    sys.exit(1)
print("GATE PASSED — every binary satisfies ldid's end >= size - 0x10 check.")
