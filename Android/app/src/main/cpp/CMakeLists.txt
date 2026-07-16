cmake_minimum_required(VERSION 3.22.1)
project(vibestation5_native LANGUAGES C CXX)

get_filename_component(VIBESTATION_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)
set(CAPSTONE_ROOT "${VIBESTATION_ROOT}/Vendor/Capstone")

add_library(vibestation_capstone STATIC
    "${CAPSTONE_ROOT}/cs.c"
    "${CAPSTONE_ROOT}/utils.c"
    "${CAPSTONE_ROOT}/SStream.c"
    "${CAPSTONE_ROOT}/MCInstrDesc.c"
    "${CAPSTONE_ROOT}/MCRegisterInfo.c"
    "${CAPSTONE_ROOT}/MCInst.c"
    "${CAPSTONE_ROOT}/Mapping.c"
    "${CAPSTONE_ROOT}/vibestation_capstone.c"
    "${CAPSTONE_ROOT}/arch/X86/X86DisassemblerDecoder.c"
    "${CAPSTONE_ROOT}/arch/X86/X86Disassembler.c"
    "${CAPSTONE_ROOT}/arch/X86/X86InstPrinterCommon.c"
    "${CAPSTONE_ROOT}/arch/X86/X86IntelInstPrinter.c"
    "${CAPSTONE_ROOT}/arch/X86/X86ATTInstPrinter.c"
    "${CAPSTONE_ROOT}/arch/X86/X86Mapping.c"
    "${CAPSTONE_ROOT}/arch/X86/X86Module.c"
)
target_compile_definitions(vibestation_capstone PRIVATE CAPSTONE_HAS_X86 CAPSTONE_USE_SYS_DYN_MEM)
target_compile_options(vibestation_capstone PRIVATE -O2)
target_include_directories(vibestation_capstone PUBLIC "${CAPSTONE_ROOT}/include")
target_include_directories(vibestation_capstone PRIVATE "${CAPSTONE_ROOT}" "${CAPSTONE_ROOT}/arch/X86")
set_target_properties(vibestation_capstone PROPERTIES POSITION_INDEPENDENT_CODE ON)

add_library(vibestation5_native SHARED
    gpu-vulkan.cpp
    native-lib.cpp
    runtime-core.cpp
    runtime-jni.cpp
)

target_compile_features(vibestation5_native PRIVATE cxx_std_20)
target_compile_options(vibestation5_native PRIVATE -O2 -Wall -Wextra -Werror)
target_link_libraries(vibestation5_native PRIVATE vibestation_capstone vulkan log)
