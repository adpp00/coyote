cmake_minimum_required(VERSION 3.5)
project(example_14_perf_nvme)

set(CYT_DIR ${CMAKE_SOURCE_DIR}/../../../)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CYT_DIR}/cmake)
find_package(CoyoteSW REQUIRED)

message("*** Coyote Example 14: NVMe Bandwidth Test [Software] ***")

set(TARGET_DIR "${CMAKE_SOURCE_DIR}/src/")
set(EXEC test)
add_executable(${EXEC} ${TARGET_DIR}/main.cpp)
target_link_libraries(${EXEC} PUBLIC Coyote)
target_link_directories(${EXEC} PUBLIC /usr/local/lib)
