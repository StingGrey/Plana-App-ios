cmake_minimum_required(VERSION 3.10)
project(plana_upscale)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 用预编译 ncnn(自带 cmake config;含 vulkan/glslang 依赖的 INTERFACE link)
set(ncnn_DIR ${CMAKE_CURRENT_SOURCE_DIR}/ncnn/lib/cmake/ncnn)
find_package(ncnn REQUIRED)

add_library(plana_upscale SHARED
    upscale_jni.cpp
    realesrgan.cpp
)

target_include_directories(plana_upscale PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(plana_upscale ncnn android log jnigraphics)
