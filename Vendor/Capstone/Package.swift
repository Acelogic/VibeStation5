// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Capstone",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "CCapstone", targets: ["CCapstone"])
    ],
    targets: [
        .target(
            name: "CCapstone",
            path: ".",
            sources: [
                "cs.c",
                "utils.c",
                "SStream.c",
                "MCInstrDesc.c",
                "MCRegisterInfo.c",
                "MCInst.c",
                "Mapping.c",
                "vibestation_capstone.c",
                "arch/X86/X86DisassemblerDecoder.c",
                "arch/X86/X86Disassembler.c",
                "arch/X86/X86InstPrinterCommon.c",
                "arch/X86/X86IntelInstPrinter.c",
                "arch/X86/X86ATTInstPrinter.c",
                "arch/X86/X86Mapping.c",
                "arch/X86/X86Module.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("CAPSTONE_HAS_X86"),
                .define("CAPSTONE_USE_SYS_DYN_MEM"),
                .headerSearchPath("."),
                .headerSearchPath("arch/X86")
            ]
        )
    ]
)
