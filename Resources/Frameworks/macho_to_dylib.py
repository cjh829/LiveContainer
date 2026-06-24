#!/usr/bin/env python3
"""
Convert a thin arm64 Mach-O executable (MH_EXECUTE) into a dylib (MH_DYLIB) so
it can be dlopen()'d, mirroring the in-place changes LiveContainer's
LCPatchExecSlice() does at runtime (minus tweak-loader injection):

  * filetype  MH_EXECUTE (0x2) -> MH_DYLIB (0x6)
  * flags     clear MH_PIE (0x200000), set MH_NO_REEXPORTED_DYLIBS (0x100000)
  * __PAGEZERO segment shrunk to a single page so the dylib can be mapped
  * insert an LC_ID_DYLIB if missing (Xcode's bitcode_strip/embed pipeline
    rejects an MH_DYLIB without one, even though dlopen tolerates it)

After this the binary's code signature is invalid and MUST be re-signed.
"""
import sys, struct

MH_MAGIC_64 = 0xFEEDFACF
MH_EXECUTE  = 0x2
MH_DYLIB    = 0x6
MH_PIE      = 0x200000
MH_NO_REEXPORTED_DYLIBS = 0x100000
LC_SEGMENT_64 = 0x19
LC_ID_DYLIB   = 0xD
ID_DYLIB_NAME = b"@rpath/BundledApp"

def patch(path):
    with open(path, "rb") as f:
        data = bytearray(f.read())

    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != MH_MAGIC_64:
        raise SystemExit(f"not a thin 64-bit little-endian Mach-O (magic={magic:#x}); "
                         "lipo -thin arm64 first")

    # mach_header_64: magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved
    filetype = struct.unpack_from("<I", data, 12)[0]
    if filetype not in (MH_EXECUTE, MH_DYLIB):
        raise SystemExit(f"unexpected filetype {filetype:#x}")
    struct.pack_into("<I", data, 12, MH_DYLIB)

    ncmds = struct.unpack_from("<I", data, 16)[0]
    sizeofcmds = struct.unpack_from("<I", data, 20)[0]
    flags = struct.unpack_from("<I", data, 24)[0]
    flags = (flags & ~MH_PIE) | MH_NO_REEXPORTED_DYLIBS
    struct.pack_into("<I", data, 24, flags)

    # walk load commands: shrink __PAGEZERO, note LC_ID_DYLIB, find header slack
    has_id_dylib = False
    min_sect_off = None
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_ID_DYLIB:
            has_id_dylib = True
        elif cmd == LC_SEGMENT_64:
            vmaddr = struct.unpack_from("<Q", data, off+24)[0]
            if vmaddr == 0:  # __PAGEZERO
                struct.pack_into("<Q", data, off+24, 0x100000000 - 0x4000)  # vmaddr
                struct.pack_into("<Q", data, off+32, 0x4000)                # vmsize
            nsects = struct.unpack_from("<I", data, off+64)[0]
            soff = off + 72
            for _s in range(nsects):
                s_offset = struct.unpack_from("<I", data, soff+48)[0]
                if s_offset > 0:
                    min_sect_off = s_offset if min_sect_off is None else min(min_sect_off, s_offset)
                soff += 80
        off += cmdsize

    if not has_id_dylib:
        cmdsize = 24 + len(ID_DYLIB_NAME) + 1
        cmdsize = (cmdsize + 7) & ~7
        free = (min_sect_off if min_sect_off is not None else len(data)) - (32 + sizeofcmds)
        if free < cmdsize:
            raise SystemExit(f"no header slack for LC_ID_DYLIB (need {cmdsize}, have {free})")
        insert_at = 32 + sizeofcmds
        lc = struct.pack("<IIIIII", LC_ID_DYLIB, cmdsize, 24, 0, 0x10000, 0x10000)
        lc += ID_DYLIB_NAME + b"\x00" * (cmdsize - 24 - len(ID_DYLIB_NAME))
        data[insert_at:insert_at + cmdsize] = lc
        struct.pack_into("<I", data, 16, ncmds + 1)            # ncmds
        struct.pack_into("<I", data, 20, sizeofcmds + cmdsize) # sizeofcmds

    with open(path, "wb") as f:
        f.write(data)
    print(f"[patch] {path}: -> MH_DYLIB, flags={flags:#x}, "
          f"id_dylib={'kept' if has_id_dylib else 'added'}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: macho_to_dylib.py <thin-arm64-macho>")
    patch(sys.argv[1])
