cmake_minimum_required(VERSION 3.22)
project(aaprobe CXX)

add_library(aaprobe SHARED aaprobe.cpp)
target_link_libraries(aaprobe aaudio log dl)
