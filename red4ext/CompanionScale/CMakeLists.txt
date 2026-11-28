cmake_minimum_required(VERSION 3.24)
project(CompanionScale VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

include(FetchContent)
# RED4ext.SDK pinned to a commit whose latest runtime is game 2.50 (Api/v1/Runtime.hpp), the version the pose-apply
# offset in src/Main.cpp was measured on.
FetchContent_Declare(
  red4ext_sdk
  GIT_REPOSITORY https://github.com/WopsS/RED4ext.SDK.git
  GIT_TAG a34f0ad0a9e4f37cbe1fe001e4ff68c2949d0665
)
set(RED4EXT_HEADER_ONLY ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(red4ext_sdk)

add_library(CompanionScale SHARED src/Main.cpp)
target_link_libraries(CompanionScale PRIVATE RED4ext::SDK)
target_compile_definitions(CompanionScale PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX)
target_compile_options(CompanionScale PRIVATE /EHsc /W3)
