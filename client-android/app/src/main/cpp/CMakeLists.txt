cmake_minimum_required(VERSION 3.22)
project(mbaudio CXX)

# T-100 / decision 0012: one AAudio output stream (open, write, timestamp, close). Audio logic stays in Kotlin.
add_library(mbaudio SHARED mbaudio.cpp)
target_link_libraries(mbaudio aaudio dl)
