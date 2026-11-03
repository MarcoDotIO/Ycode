// yc_macho.h - Mach-O format facts used by Ycode's dynamic linker and its
// host tests (specs/macos/dyld.md §2). Clean-room Ycode code: the values are
// interoperability facts from the public <mach-o/loader.h>,
// <mach-o/fixup-chains.h> and <mach-o/nlist.h> headers (evidence level 1);
// the declarations are our own.
#ifndef YC_MACHO_H
#define YC_MACHO_H

#include <stdint.h>

#define YC_MH_MAGIC_64 0xFEEDFACFu
#define YC_FAT_MAGIC 0xCAFEBABEu     /* big-endian on disk */
#define YC_FAT_MAGIC_64 0xCAFEBABFu  /* big-endian on disk */
#define YC_CPU_TYPE_ARM64 0x0100000Cu

#define YC_MH_EXECUTE 2u
#define YC_MH_DYLIB 6u
#define YC_MH_DYLINKER 7u
#define YC_MH_BUNDLE 8u

#define YC_LC_REQ_DYLD 0x80000000u
#define YC_LC_SEGMENT_64 0x19u
#define YC_LC_SYMTAB 0x2u
#define YC_LC_UNIXTHREAD 0x5u
#define YC_LC_DYSYMTAB 0xBu
#define YC_LC_LOAD_DYLIB 0xCu
#define YC_LC_ID_DYLIB 0xDu
#define YC_LC_LOAD_DYLINKER 0xEu
#define YC_LC_ID_DYLINKER 0xFu
#define YC_LC_LOAD_WEAK_DYLIB (0x18u | YC_LC_REQ_DYLD)
#define YC_LC_RPATH (0x1Cu | YC_LC_REQ_DYLD)
#define YC_LC_REEXPORT_DYLIB (0x1Fu | YC_LC_REQ_DYLD)
#define YC_LC_DYLD_INFO 0x22u
#define YC_LC_DYLD_INFO_ONLY (0x22u | YC_LC_REQ_DYLD)
#define YC_LC_LOAD_UPWARD_DYLIB (0x23u | YC_LC_REQ_DYLD)
#define YC_LC_MAIN (0x28u | YC_LC_REQ_DYLD)
#define YC_LC_BUILD_VERSION 0x32u
#define YC_LC_DYLD_EXPORTS_TRIE (0x33u | YC_LC_REQ_DYLD)
#define YC_LC_DYLD_CHAINED_FIXUPS (0x34u | YC_LC_REQ_DYLD)

#define YC_PLATFORM_MACOS 1u

#define YC_VM_PROT_READ 1
#define YC_VM_PROT_WRITE 2
#define YC_VM_PROT_EXECUTE 4

#define YC_SG_READ_ONLY 0x10u

/* section flags: type in the low byte */
#define YC_SECTION_TYPE 0xFFu
#define YC_S_ZEROFILL 0x1u
#define YC_S_MOD_INIT_FUNC_POINTERS 0x9u
#define YC_S_MOD_TERM_FUNC_POINTERS 0xAu
#define YC_S_THREAD_LOCAL_REGULAR 0x11u
#define YC_S_THREAD_LOCAL_ZEROFILL 0x12u
#define YC_S_THREAD_LOCAL_VARIABLES 0x13u
#define YC_S_INIT_FUNC_OFFSETS 0x16u

struct yc_mach_header_64 {
    uint32_t magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved;
};

struct yc_load_command {
    uint32_t cmd, cmdsize;
};

struct yc_segment_command_64 {
    uint32_t cmd, cmdsize;
    char segname[16];
    uint64_t vmaddr, vmsize, fileoff, filesize;
    int32_t maxprot, initprot;
    uint32_t nsects, flags;
};

struct yc_section_64 {
    char sectname[16];
    char segname[16];
    uint64_t addr, size;
    uint32_t offset, align, reloff, nreloc, flags, reserved1, reserved2, reserved3;
};

struct yc_dylib_command {
    uint32_t cmd, cmdsize;
    uint32_t name_offset, timestamp, current_version, compatibility_version;
};

struct yc_rpath_command {
    uint32_t cmd, cmdsize, path_offset;
};

struct yc_entry_point_command {
    uint32_t cmd, cmdsize;
    uint64_t entryoff, stacksize;
};

struct yc_linkedit_data_command {
    uint32_t cmd, cmdsize, dataoff, datasize;
};

struct yc_dyld_info_command {
    uint32_t cmd, cmdsize;
    uint32_t rebase_off, rebase_size, bind_off, bind_size, weak_bind_off, weak_bind_size;
    uint32_t lazy_bind_off, lazy_bind_size, export_off, export_size;
};

struct yc_build_version_command {
    uint32_t cmd, cmdsize, platform, minos, sdk, ntools;
};

/* <mach-o/fixup-chains.h> */
struct yc_chained_fixups_header {
    uint32_t fixups_version, starts_offset, imports_offset, symbols_offset;
    uint32_t imports_count, imports_format, symbols_format;
};

#define YC_CHAINED_IMPORT 1u
#define YC_CHAINED_IMPORT_ADDEND 2u
#define YC_CHAINED_IMPORT_ADDEND64 3u

#define YC_CHAINED_PTR_64 2u
#define YC_CHAINED_PTR_64_OFFSET 6u
#define YC_CHAINED_PTR_START_NONE 0xFFFFu
#define YC_CHAINED_PTR_START_MULTI 0x8000u

/* special library ordinals (bind and import records) */
#define YC_BIND_SELF 0
#define YC_BIND_MAIN_EXECUTABLE (-1)
#define YC_BIND_FLAT_LOOKUP (-2)
#define YC_BIND_WEAK_LOOKUP (-3)

/* export trie terminal flags */
#define YC_EXPORT_KIND_MASK 0x03u
#define YC_EXPORT_KIND_REGULAR 0x00u
#define YC_EXPORT_KIND_THREAD_LOCAL 0x01u
#define YC_EXPORT_KIND_ABSOLUTE 0x02u
#define YC_EXPORT_WEAK_DEFINITION 0x04u
#define YC_EXPORT_REEXPORT 0x08u
#define YC_EXPORT_STUB_AND_RESOLVER 0x10u

/* classic rebase/bind opcodes (LC_DYLD_INFO) */
#define YC_REBASE_TYPE_POINTER 1
#define YC_REBASE_OPCODE_MASK 0xF0
#define YC_REBASE_IMMEDIATE_MASK 0x0F
#define YC_REBASE_OPCODE_DONE 0x00
#define YC_REBASE_OPCODE_SET_TYPE_IMM 0x10
#define YC_REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB 0x20
#define YC_REBASE_OPCODE_ADD_ADDR_ULEB 0x30
#define YC_REBASE_OPCODE_ADD_ADDR_IMM_SCALED 0x40
#define YC_REBASE_OPCODE_DO_REBASE_IMM_TIMES 0x50
#define YC_REBASE_OPCODE_DO_REBASE_ULEB_TIMES 0x60
#define YC_REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB 0x70
#define YC_REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB 0x80

#define YC_BIND_TYPE_POINTER 1
#define YC_BIND_SYMBOL_FLAGS_WEAK_IMPORT 0x1
#define YC_BIND_OPCODE_MASK 0xF0
#define YC_BIND_IMMEDIATE_MASK 0x0F
#define YC_BIND_OPCODE_DONE 0x00
#define YC_BIND_OPCODE_SET_DYLIB_ORDINAL_IMM 0x10
#define YC_BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB 0x20
#define YC_BIND_OPCODE_SET_DYLIB_SPECIAL_IMM 0x30
#define YC_BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM 0x40
#define YC_BIND_OPCODE_SET_TYPE_IMM 0x50
#define YC_BIND_OPCODE_SET_ADDEND_SLEB 0x60
#define YC_BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB 0x70
#define YC_BIND_OPCODE_ADD_ADDR_ULEB 0x80
#define YC_BIND_OPCODE_DO_BIND 0x90
#define YC_BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB 0xA0
#define YC_BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED 0xB0
#define YC_BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB 0xC0
#define YC_BIND_OPCODE_THREADED 0xD0

#endif
