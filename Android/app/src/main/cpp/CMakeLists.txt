cmake_minimum_required(VERSION 3.22.1)
project(vibestation5_native LANGUAGES CXX)

add_library(vibestation5_native SHARED native-lib.cpp)

target_compile_features(vibestation5_native PRIVATE cxx_std_20)
target_compile_options(vibestation5_native PRIVATE -Wall -Wextra -Werror)
