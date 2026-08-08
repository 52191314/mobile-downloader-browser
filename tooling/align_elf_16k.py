#!/usr/bin/env python3
"""Re-align a shared object's PT_LOAD segments to 16 KB page size.

Google Play requires (since Nov 2025) that every native library in an AAB
has ELF LOAD segments aligned to >= 16 KB (0x4000).  Prebuilt third-party
libs (e.g. libtorrent_flutter's android-native-lib-*.zip) are linked with
`-Wl,-z,max-page-size=4096`, so they fail the check.

This script performs the same transformation the linker would do with
`-Wl,-z,max-page-size=16384`, but on an already-linked .so:

  * For each PT_LOAD segment it inserts padding bytes *in the file* before
    the segment so that `(p_vaddr - p_offset) % 0x4000 == 0`.
  * It sets p_align = 0x4000 on every PT_LOAD.
  * Virtual addresses are NEVER changed, so no relocation, symbol, or
    .dynamic entry needs to move.  Only file offsets shift, which is safe:
    loaders map segments independently and only require the congruence.

A plain p_align=0x4000 bump *without* re-aligning the file offsets would
pass Play's static check but crash with EINVAL on a real 16 KB device
(unaligned mmap) - that is exactly what this script avoids.

Usage:
    python align_elf_16k.py <lib.so> [<lib_aligned.so>]
    (when the output path is omitted the file is aligned in place)

Verifies the result before writing: every PT_LOAD must end up with
p_align >= 0x4000 and (p_vaddr - p_offset) % 0x4000 == 0.

Works on ELF32 and ELF64, little-endian. No third-party dependencies.
"""

import struct
import sys

PAGE = 0x4000  # 16 KB
PT_LOAD = 1


def parse_elf(data):
    if data[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    if data[5] != 1:
        raise ValueError("big-endian ELF not supported")
    is64 = data[4] == 2
    if is64:
        e_phoff, e_shoff = struct.unpack_from("<QQ", data, 32)
        e_phentsize, e_phnum = struct.unpack_from("<HH", data, 54)
        e_shentsize, e_shnum = struct.unpack_from("<HH", data, 58)
        e_shstrndx = struct.unpack_from("<H", data, 62)[0]
        PH = "<IIQQQQQQ"
        PH_SZ = 56
        SH = "<IIQQQQIIQQ"
        SH_SZ = 64
    else:
        e_phoff, e_shoff = struct.unpack_from("<II", data, 28)
        e_phentsize, e_phnum = struct.unpack_from("<HH", data, 42)
        e_shentsize, e_shnum = struct.unpack_from("<HH", data, 46)
        e_shstrndx = struct.unpack_from("<H", data, 50)[0]
        PH = "<IIIIIIII"
        PH_SZ = 32
        SH = "<IIIIIIIIII"
        SH_SZ = 40

    phdrs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        phdrs.append(struct.unpack_from(PH, data, off))

    shdrs = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        shdrs.append(struct.unpack_from(SH, data, off))

    return {
        "is64": is64,
        "e_phoff": e_phoff, "e_shoff": e_shoff,
        "e_phentsize": e_phentsize, "e_phnum": e_phnum,
        "e_shentsize": e_shentsize, "e_shnum": e_shnum,
        "PH": PH, "PH_SZ": PH_SZ, "SH": SH, "SH_SZ": SH_SZ,
        "phdrs": phdrs, "shdrs": shdrs,
        # PT_LOAD field indices differ between classes:
        #   ELF64 phdr: (p_type, p_flags, p_offset, p_vaddr, p_paddr, ...)
        #   ELF32 phdr: (p_type, p_offset, p_vaddr, p_paddr, ...)  (no p_flags gap)
        "P_OFF": 2 if is64 else 1,
        "P_VADDR": 3 if is64 else 2,
    }


def load_segments(phdrs, p_off):
    """Return PT_LOAD phdr indexes sorted by file offset."""
    idxs = [i for i, p in enumerate(phdrs) if p[0] == PT_LOAD]
    return sorted(idxs, key=lambda i: phdrs[i][p_off])


def compute_pads(phdrs, loads, p_off, p_vaddr):
    """Return {phdr_idx: pad_bytes} and total padding."""
    pads = {}
    cum = 0
    for i in loads:
        ph = phdrs[i]
        new_off = ph[p_off] + cum
        # want (p_vaddr - (new_off + pad)) % PAGE == 0
        pad = (ph[p_vaddr] - new_off) % PAGE
        pads[i] = pad
        cum += pad
    return pads, cum


def shift_at(pads, loads, phdrs, p_off, x):
    """Padding inserted before file offset x (sum of pads of LOADs starting <= x)."""
    return sum(pads[i] for i in loads if phdrs[i][p_off] <= x)


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit("usage: python align_elf_16k.py <lib.so> [<output.so>]")
    src, dst = sys.argv[1], (sys.argv[2] if len(sys.argv) == 3 else sys.argv[1])

    with open(src, "rb") as f:
        data = f.read()

    e = parse_elf(data)
    phdrs, shdrs = e["phdrs"], e["shdrs"]
    P_OFF, P_VADDR = e["P_OFF"], e["P_VADDR"]
    # p_filesz / p_memsz / p_align indices (same position in both classes
    # relative to the class layout; p_align is the last field either way).
    P_FILESZ, P_MEMSZ, P_ALIGN = (5, 6, 7) if e["is64"] else (4, 5, 7)
    loads = load_segments(phdrs, P_OFF)
    if not loads:
        sys.exit("no PT_LOAD segments found")

    pads, total_pad = compute_pads(phdrs, loads, P_OFF, P_VADDR)

    if all(phdrs[i][P_ALIGN] >= PAGE and
           (phdrs[i][P_VADDR] - phdrs[i][P_OFF]) % PAGE == 0
           for i in loads):
        print(f"{src}: already 16 KB aligned, no changes")
        return 0

    # --- rebuild file: header + segments with padding inserted before each ---
    out = bytearray()
    prev_end = 0
    for i in loads:
        ph = phdrs[i]
        out += data[prev_end:ph[P_OFF]]
        out += b"\x00" * pads[i]
        out += data[ph[P_OFF]:ph[P_OFF] + ph[P_FILESZ]]
        prev_end = ph[P_OFF] + ph[P_FILESZ]
    out += data[prev_end:]

    # --- rewrite program headers (phdr table stays at e_phoff, before any padding) ---
    for i in range(e["e_phnum"]):
        ph = list(phdrs[i])
        ph[P_OFF] += shift_at(pads, loads, phdrs, P_OFF, ph[P_OFF])
        if i in pads:
            ph[P_ALIGN] = PAGE  # p_align
        struct.pack_into(e["PH"], out, e["e_phoff"] + i * e["e_phentsize"], *ph)

    # --- rewrite section headers (table itself shifted by total_pad) ---
    table_off = e["e_shoff"] + total_pad
    for i in range(e["e_shnum"]):
        sh = list(shdrs[i])
        if sh[4] != 0:  # sh_offset
            sh[4] += shift_at(pads, loads, phdrs, P_OFF, sh[4])
        struct.pack_into(e["SH"], out, table_off + i * e["e_shentsize"], *sh)

    # --- move the section header table to the end of the file ---
    struct.pack_into("<Q" if e["is64"] else "<I", out, 40 if e["is64"] else 32,
                     table_off)

    out = bytes(out)

    # --- verify ---
    v = parse_elf(out)
    v_off, v_vaddr = v["P_OFF"], v["P_VADDR"]
    v_align = 7
    for i in load_segments(v["phdrs"], v_off):
        p = v["phdrs"][i]
        if p[v_align] < PAGE or (p[v_vaddr] - p[v_off]) % PAGE != 0:
            sys.exit(f"VERIFY FAILED on phdr {i}: offset={p[v_off]:#x} vaddr={p[v_vaddr]:#x} align={p[v_align]:#x}")
    # every phdr and shdr must sit exactly where the rebuild intended
    for i, p in enumerate(v["phdrs"]):
        expect = phdrs[i][P_OFF] + shift_at(pads, loads, phdrs, P_OFF, phdrs[i][P_OFF])
        if p[P_OFF] != expect:
            sys.exit(f"VERIFY FAILED: phdr {i} offset {p[P_OFF]:#x} != expected {expect:#x}")
    for i, s in enumerate(v["shdrs"]):
        if shdrs[i][4] != 0:
            expect = shdrs[i][4] + shift_at(pads, loads, phdrs, P_OFF, shdrs[i][4])
            if s[4] != expect:
                sys.exit(f"VERIFY FAILED: section {i} offset {s[4]:#x} != expected {expect:#x}")
    with open(dst, "wb") as f:
        f.write(out)

    print(f"{src}: aligned {len(data)} -> {len(out)} bytes (+{len(out) - len(data)} "
          f"padding), all PT_LOAD now 16 KB-aligned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
