cmake_minimum_required(VERSION 3.22.1)
project(openpay_activation C)
include(ExternalProject)

set(LIBSODIUM_SOURCE_DIR "${CMAKE_CURRENT_LIST_DIR}/libsodium")
if(NOT EXISTS "${LIBSODIUM_SOURCE_DIR}/configure")
    message(FATAL_ERROR
        "Native activation builds are supported only through Dockerfile.ci. "
        "It verifies official libsodium 1.0.21 with Minisign before supplying ${LIBSODIUM_SOURCE_DIR}.")
endif()

if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(LIBSODIUM_HOST aarch64-linux-android)
elseif(ANDROID_ABI STREQUAL "armeabi-v7a")
    set(LIBSODIUM_HOST armv7a-linux-androideabi)
elseif(ANDROID_ABI STREQUAL "x86_64")
    set(LIBSODIUM_HOST x86_64-linux-android)
else()
    message(FATAL_ERROR "Unsupported Android ABI: ${ANDROID_ABI}")
endif()

set(LIBSODIUM_INSTALL "${CMAKE_BINARY_DIR}/libsodium-install")
ExternalProject_Add(libsodium_project
    SOURCE_DIR "${LIBSODIUM_SOURCE_DIR}"
    BINARY_DIR "${CMAKE_BINARY_DIR}/libsodium-build"
    CONFIGURE_COMMAND ${CMAKE_COMMAND} -E env CC=${CMAKE_C_COMPILER} AR=${CMAKE_AR} RANLIB=${CMAKE_RANLIB}
        "${LIBSODIUM_SOURCE_DIR}/configure" --host=${LIBSODIUM_HOST} --prefix=${LIBSODIUM_INSTALL} --disable-shared --enable-static
    BUILD_COMMAND ${CMAKE_MAKE_PROGRAM}
    INSTALL_COMMAND ${CMAKE_MAKE_PROGRAM} install
    UPDATE_COMMAND ""
)

add_library(libsodium STATIC IMPORTED GLOBAL)
set_target_properties(libsodium PROPERTIES IMPORTED_LOCATION "${LIBSODIUM_INSTALL}/lib/libsodium.a")
add_dependencies(libsodium libsodium_project)
add_library(openpay_activation SHARED activation_jni.c)
target_include_directories(openpay_activation PRIVATE "${LIBSODIUM_INSTALL}/include")
target_link_libraries(openpay_activation libsodium log)
