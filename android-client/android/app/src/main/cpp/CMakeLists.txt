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
find_program(LIBSODIUM_MAKE_EXECUTABLE NAMES make REQUIRED)
get_filename_component(LIBSODIUM_TOOLCHAIN_BIN "${CMAKE_C_COMPILER}" DIRECTORY)
string(REGEX REPLACE "^android-" "" LIBSODIUM_ANDROID_API "${ANDROID_PLATFORM}")

if(NOT LIBSODIUM_ANDROID_API MATCHES "^[0-9]+$")
    message(FATAL_ERROR "Unsupported Android platform: ${ANDROID_PLATFORM}")
endif()

set(LIBSODIUM_TARGET_COMPILER
    "${LIBSODIUM_TOOLCHAIN_BIN}/${LIBSODIUM_HOST}${LIBSODIUM_ANDROID_API}-clang")

if(NOT EXISTS "${LIBSODIUM_TARGET_COMPILER}")
    message(FATAL_ERROR
        "Missing target compiler for ${ANDROID_ABI}: ${LIBSODIUM_TARGET_COMPILER}")
endif()

ExternalProject_Add(libsodium_project
    SOURCE_DIR "${LIBSODIUM_SOURCE_DIR}"
    BINARY_DIR "${CMAKE_BINARY_DIR}/libsodium-build"
    CONFIGURE_COMMAND ${CMAKE_COMMAND} -E env CC=${LIBSODIUM_TARGET_COMPILER} AR=${CMAKE_AR} RANLIB=${CMAKE_RANLIB}
        "${LIBSODIUM_SOURCE_DIR}/configure" --host=${LIBSODIUM_HOST} --prefix=${LIBSODIUM_INSTALL} --disable-shared --enable-static
    # CMake 3.22 cannot declare INSTALL_BYPRODUCTS. Make install the build
    # step so Ninja receives the static archive as a real build byproduct.
    BUILD_COMMAND ${LIBSODIUM_MAKE_EXECUTABLE} install
    BUILD_BYPRODUCTS "${LIBSODIUM_INSTALL}/lib/libsodium.a"
    INSTALL_COMMAND ""
    UPDATE_COMMAND ""
)

add_library(libsodium STATIC IMPORTED GLOBAL)
set_target_properties(libsodium PROPERTIES IMPORTED_LOCATION "${LIBSODIUM_INSTALL}/lib/libsodium.a")
add_dependencies(libsodium libsodium_project)
add_library(openpay_activation SHARED activation_jni.c pairing_v2_native.c)
# Imported-library dependencies are not emitted as Ninja link prerequisites.
# Make every ABI's shared-library link wait for its own ExternalProject install.
add_dependencies(openpay_activation libsodium_project)
target_include_directories(openpay_activation PRIVATE "${LIBSODIUM_INSTALL}/include")
target_link_libraries(openpay_activation libsodium log)
