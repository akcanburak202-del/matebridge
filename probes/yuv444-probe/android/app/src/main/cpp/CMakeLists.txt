cmake_minimum_required(VERSION 3.22)
project(y444native CXX)

# T-254 probe only: EGL/GLES import of AHardwareBuffer images (raw YUV sampling, merge pass, frame timestamps)
# and a Vulkan capability query. Not product code.
add_library(y444native SHARED y444native.cpp)
target_link_libraries(y444native EGL GLESv3 android vulkan log)
