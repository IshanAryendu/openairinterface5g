#find_package(Boost REQUIRED)
find_package(UHD REQUIRED)

add_library(oai_usrpdevif MODULE usrp_lib.cpp)
#target_include_directories(oai_usrpdevif PRIVATE Boost::boost)
target_link_libraries(oai_usrpdevif PRIVATE uhd)
target_link_libraries(oai_usrpdevif PRIVATE UTIL)
# Local PoC patch: UHD >= 4.8 headers require C++17; OAI global flags use -std=c++11.
target_compile_options(oai_usrpdevif PRIVATE -std=c++17)
# Local PoC patch: usrp_lib.cpp uses boost::this_thread; UHD >= 4.10 no longer links boost_thread for us.
find_package(Boost REQUIRED COMPONENTS thread)
target_link_libraries(oai_usrpdevif PRIVATE Boost::thread)
set_target_properties(oai_usrpdevif PROPERTIES LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
add_custom_command(TARGET oai_usrpdevif POST_BUILD
                   COMMAND ${CMAKE_COMMAND} -E create_symlink liboai_usrpdevif.so liboai_device.so
                   WORKING_DIRECTORY ${CMAKE_BINARY_DIR})
