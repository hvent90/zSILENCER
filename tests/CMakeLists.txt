# All test sources aggregate into one binary: keeps link+run simple,
# doctest handles discovery via its built-in main().
set(TEST_SRC
    smoke_test.cpp
)

add_executable(zsilencer_tests ${TEST_SRC})
target_compile_features(zsilencer_tests PUBLIC cxx_std_14)
target_include_directories(zsilencer_tests PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/src
)

enable_testing()
add_test(NAME zsilencer_tests COMMAND zsilencer_tests)
