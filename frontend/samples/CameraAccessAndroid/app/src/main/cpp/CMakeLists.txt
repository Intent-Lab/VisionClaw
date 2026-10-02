cmake_minimum_required(VERSION 3.10)

project(jarvis_whisper)

set(CMAKE_CXX_STANDARD 17)
set(WHISPER_ROOT ${CMAKE_SOURCE_DIR}/whisper)
set(WHISPER_VERSION "local")

find_library(LOG_LIB log)

include(FetchContent)

set(SOURCE_FILES
    ${WHISPER_ROOT}/src/whisper.cpp
    ${CMAKE_SOURCE_DIR}/whisper_jni.c
)

function(build_whisper_library target_name)
    add_library(${target_name} SHARED ${SOURCE_FILES})

    target_compile_definitions(${target_name} PUBLIC GGML_USE_CPU)
    target_compile_definitions(${target_name} PRIVATE WHISPER_VERSION="${WHISPER_VERSION}")

    if (${target_name} STREQUAL "jarvis_whisper_v8fp16_va")
        target_compile_options(${target_name} PRIVATE -march=armv8.2-a+fp16)
        set(GGML_COMPILE_OPTIONS -march=armv8.2-a+fp16)
    elseif (${target_name} STREQUAL "jarvis_whisper_vfpv4")
        target_compile_options(${target_name} PRIVATE -mfpu=neon-vfpv4)
        set(GGML_COMPILE_OPTIONS -mfpu=neon-vfpv4)
    endif ()

    if (NOT ${CMAKE_BUILD_TYPE} STREQUAL "Debug")
        target_compile_options(${target_name} PRIVATE -O3)
        target_compile_options(${target_name} PRIVATE -fvisibility=hidden -fvisibility-inlines-hidden)
        target_compile_options(${target_name} PRIVATE -ffunction-sections -fdata-sections)
        target_link_options(${target_name} PRIVATE -Wl,--gc-sections)
        target_link_options(${target_name} PRIVATE -Wl,--exclude-libs,ALL)
        target_link_options(${target_name} PRIVATE -flto)
    endif ()

    FetchContent_Declare(ggml SOURCE_DIR ${WHISPER_ROOT}/ggml)
    FetchContent_MakeAvailable(ggml)
    target_compile_options(ggml PRIVATE ${GGML_COMPILE_OPTIONS})
    target_link_libraries(${target_name} ${LOG_LIB} android ggml)
    target_include_directories(${target_name} PRIVATE
        ${WHISPER_ROOT}
        ${WHISPER_ROOT}/src
        ${WHISPER_ROOT}/include
        ${WHISPER_ROOT}/ggml/include
        ${WHISPER_ROOT}/ggml/src
        ${WHISPER_ROOT}/ggml/src/ggml-cpu
    )
endfunction()

if (${ANDROID_ABI} STREQUAL "arm64-v8a")
    build_whisper_library("jarvis_whisper_v8fp16_va")
elseif (${ANDROID_ABI} STREQUAL "armeabi-v7a")
    build_whisper_library("jarvis_whisper_vfpv4")
endif ()

build_whisper_library("jarvis_whisper")
