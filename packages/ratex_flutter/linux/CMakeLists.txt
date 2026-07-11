# Builds the shared `ratex_ffi` Rust crate via cargokit and bundles the
# resulting libratex_ffi.so with the Flutter app.
cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "ratex_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

include("${CMAKE_CURRENT_SOURCE_DIR}/../cargokit/cmake/cargokit.cmake")

# apply_cargokit(<target> <manifest_dir, relative to this file> <lib_name> <force-link symbol>)
# The crate lives at the repo root, shared with the pure-Dart `ratex` package.
apply_cargokit(${PROJECT_NAME} ../../../native/ratex-ffi ratex_ffi "")

set(ratex_flutter_bundled_libraries
  "${${PROJECT_NAME}_cargokit_lib}"
  PARENT_SCOPE
)
