cmake_minimum_required(VERSION 3.20)
project(mental-llvm C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# LLVM (static libraries)
find_package(LLVM REQUIRED CONFIG)
message(STATUS "Found LLVM ${LLVM_PACKAGE_VERSION}")

# Clang (static libraries)
find_package(Clang REQUIRED CONFIG)
message(STATUS "Found Clang")

# SPIRV-LLVM-Translator (static library)
find_library(LLVM_SPIRV_LIB LLVMSPIRVLib
    HINTS "${SPIRV_TRANSLATOR_DIR}/lib"
          "${LLVM_LIBRARY_DIRS}"
)
find_path(LLVM_SPIRV_INCLUDE LLVMSPIRVLib.h
    HINTS "${SPIRV_TRANSLATOR_DIR}/include"
          "${SPIRV_TRANSLATOR_DIR}/../include"
          "${LLVM_INCLUDE_DIRS}"
)
if(NOT LLVM_SPIRV_LIB)
    message(FATAL_ERROR "LLVMSPIRVLib not found. Set SPIRV_TRANSLATOR_DIR.")
endif()
message(STATUS "Found LLVMSPIRVLib: ${LLVM_SPIRV_LIB}")

# clspv (static library — provides OpenCL C → Vulkan SPIR-V)
if(CLSPV_BUILD_DIR)
    find_library(CLSPV_CORE_LIB clspv_core
        HINTS "${CLSPV_BUILD_DIR}/lib" "${CLSPV_BUILD_DIR}"
    )
    find_library(CLSPV_PASSES_LIB clspv_passes
        HINTS "${CLSPV_BUILD_DIR}/lib" "${CLSPV_BUILD_DIR}"
    )
    # clspv headers
    get_filename_component(CLSPV_SOURCE_DIR "${CLSPV_BUILD_DIR}/.." ABSOLUTE)
    set(CLSPV_INCLUDE "${CLSPV_SOURCE_DIR}/include")
    message(STATUS "Found clspv: ${CLSPV_CORE_LIB}")
endif()

# Collect all LLVM static libraries we need
llvm_map_components_to_libnames(LLVM_LIBS
    core support irreader bitreader bitwriter
    analysis passes target
    nvptx nvptxcodegen nvptxdesc nvptxinfo
    amdgpu amdgpucodegen amdgpudesc amdgpuinfo amdgpuutils
    codegen selectiondag asmprinter mc mcparser
    transformutils scalaropts instcombine ipo
    frontenddriver frontendopenacc
)

# Build the shared library — everything statically linked inside
add_library(mental-llvm SHARED mental_llvm.cpp)

target_include_directories(mental-llvm PRIVATE
    ${LLVM_INCLUDE_DIRS}
    ${CLANG_INCLUDE_DIRS}
    ${LLVM_SPIRV_INCLUDE}
    ${CLSPV_INCLUDE}
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# Static link: all LLVM + Clang + SPIRV-Translator baked into the .so
target_link_libraries(mental-llvm PRIVATE
    ${LLVM_LIBS}
    clangFrontend
    clangDriver
    clangCodeGen
    clangSema
    clangAnalysis
    clangAST
    clangLex
    clangBasic
    clangParse
    clangSerialization
    clangEdit
    ${LLVM_SPIRV_LIB}
    ${CLSPV_CORE_LIB}
    ${CLSPV_PASSES_LIB}
)

# Only export mental_llvm_* symbols — hide all LLVM/Clang internals
set_target_properties(mental-llvm PROPERTIES
    C_VISIBILITY_PRESET hidden
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
)

install(TARGETS mental-llvm DESTINATION lib)
install(FILES mental_llvm.h DESTINATION include)
