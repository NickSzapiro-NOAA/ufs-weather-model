cmake_minimum_required(VERSION 3.15)
project(UFS_QC_Coupling LANGUAGES Fortran)

# ----------------------------------------------------------------------------
# 1. Initialization & Dependencies
# ----------------------------------------------------------------------------
include(CTest)
find_package(ESMF REQUIRED)

# ----------------------------------------------------------------------------
# 2. Build the Production Library
# ----------------------------------------------------------------------------
add_library(qc_coupling qc_coupling_mod.F90)

# PUBLIC linking ensures anything that links to qc_coupling also gets ESMF
target_link_libraries(qc_coupling PUBLIC esmf)

# Put .mod files in the current binary dir so test targets can find them easily
set_target_properties(qc_coupling PROPERTIES Fortran_MODULE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR})

# ----------------------------------------------------------------------------
# 3. Conditionally add unit tests (default is ON)
# ----------------------------------------------------------------------------
if(BUILD_TESTING)
    add_subdirectory(unit_tests)
endif()
