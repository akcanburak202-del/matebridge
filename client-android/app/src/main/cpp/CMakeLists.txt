cmake_minimum_required(VERSION 3.22)
project(mbnative CXX)

# T-100 / decision 0012: one AAudio output stream (open, write, timestamp, close). Audio logic stays in Kotlin.
add_library(mbaudio SHARED mbaudio.cpp)
target_link_libraries(mbaudio aaudio dl)

# T-259 / decision 0034: packed full colour. EGL/GLES import of decoder images (AHardwareBuffer), raw YUV sampling through
# GL_EXT_YUV_target, the AVC444v2 merge pass and the window-surface presentation. The layout logic stays in Kotlin.
add_library(mbfullchroma SHARED mbfullchroma.cpp)
target_link_libraries(mbfullchroma EGL GLESv3 android log)
