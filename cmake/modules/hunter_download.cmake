# Copyright (c) 2013, Ruslan Baratov
# All rights reserved.

include(CMakeParseArguments) # CMAKE_PARSE_ARGUMENTS

include(hunter_fatal_error)
include(hunter_status_debug)
include(hunter_status_print)

function(hunter_download)
  set(
      h_one_value
      PACKAGE_NAME # Foo
      PACKAGE_COMPONENT
      DOWNLOAD_SCHEME
  )
  set(h_multiple_values DEPENDS) # Boo

  CMAKE_PARSE_ARGUMENTS(
      HUNTER "" "${h_one_value}" "${h_multiple_values}" ${ARGV}
  )

  if(h_UNPARSED_ARGUMENTS)
    hunter_fatal_error("Internal error")
  endif()

  set(versions "[${HUNTER_${HUNTER_PACKAGE_NAME}_VERSIONS}]")
  hunter_status_debug(
      "${HUNTER_PACKAGE_NAME} versions available: ${versions}"
  )

  if(NOT HUNTER_INSTALL_TAG)
    set(HUNTER_INSTALL_TAG "default")
  endif()

  # Set <LIB>_ROOT variables
  set(h_name "${HUNTER_PACKAGE_NAME}") # Foo
  string(TOUPPER "${h_name}" h_root_name) # FOO
  set(h_root_name "${h_root_name}_ROOT") # FOO_ROOT

  set(ver ${HUNTER_${h_name}_VERSION})
  if(NOT ver AND ${h_root_name})
    # function `hunter_add_version` will skip set if root already
    # defined by custom location => ver is empty
    return()
  endif()

  string(
      COMPARE
      NOTEQUAL
      "${HUNTER_DOWNLOAD_SCHEME}"
      "url_sha1_no_install"
      do_install
  )
  if(do_install)
    set(${h_root_name} "${HUNTER_BASE}/Install/${HUNTER_INSTALL_TAG}")
  else()
    set(${h_root_name} "${HUNTER_BASE}/Source/${h_name}")
  endif()
  set(${h_root_name} "${${h_root_name}}" PARENT_SCOPE)
  set(ENV{${h_root_name}} "${${h_root_name}}")
  hunter_status_print("${h_root_name}: ${${h_root_name}} (ver.: ${ver})")

  # creating temporary working directory where download project will reside
  if(NOT PROJECT_BINARY_DIR)
    message(
        FATAL_ERROR
        "PROJECT_BINARY_DIR is empty. "
        "Move file **after** first 'project' command"
    )
  endif()
  set(h_work_dir "${PROJECT_BINARY_DIR}/_HUNTER_temp_download_project")
  file(REMOVE_RECURSE "${h_work_dir}")

  # create temp toolchain file to set environment variables
  # and include real toolchain
  set(toolchain_wrapper ${h_work_dir}/toolchain.cmake)
  file(WRITE ${toolchain_wrapper} "###\n") # file must not be empty

  list(APPEND h_DEPENDS Hunter) # pass HUNTER_ROOT to all packages
  foreach(x ${h_DEPENDS})
    string(TOUPPER "${x}" x_name)
    set(x_name "${x_name}_ROOT")
    if(NOT ${x_name})
      hunter_fatal_error(
          "Can't forward empty variable ${x_name} (need include?)"
      )
    endif()

    # forward depends '<NAME>_ROOT' cmake variables
    file(APPEND ${toolchain_wrapper} "set(${x_name} ${${x_name}})\n")

    # forward depends '<NAME>_ROOT' environment variables
    file(APPEND ${toolchain_wrapper} "set(ENV{${x_name}} ${${x_name}})\n")
  endforeach()

  # support for toolchain file forwarding
  if(CMAKE_TOOLCHAIN_FILE)
    file(APPEND ${toolchain_wrapper} "include(${CMAKE_TOOLCHAIN_FILE})\n")
  endif()

  if(HUNTER_STATUS_DEBUG)
    set(verbose_makefile "-DCMAKE_VERBOSE_MAKEFILE=ON")
  endif()

  set(HUNTER_PACKAGE_INSTALL_DIR "${${h_root_name}}")
  set(HUNTER_PACKAGE_URL "${HUNTER_${h_name}_URL}")
  set(HUNTER_PACKAGE_SHA1 "${HUNTER_${h_name}_SHA1}")
  set(HUNTER_PACKAGE_DOWNLOAD_DIR "${HUNTER_BASE}/Download/${h_name}")
  set(HUNTER_PACKAGE_SOURCE_DIR "${HUNTER_BASE}/Source/${h_name}")

  if(NOT HUNTER_PACKAGE_URL)
    set(avail ${HUNTER_${h_name}_VERSIONS})
    hunter_fatal_error(
        "${h_name} version(${ver}) not found. Available: [${avail}]"
    )
  endif()

  # HUNTER_PACKAGE_BASENAME = <name[-component]-tag>
  set(HUNTER_PACKAGE_BASENAME "${HUNTER_PACKAGE_NAME}")
  if(HUNTER_PACKAGE_COMPONENT)
    set(
        HUNTER_PACKAGE_BASENAME
        "${HUNTER_PACKAGE_BASENAME}-${HUNTER_PACKAGE_COMPONENT}"
    )
  endif()
  set(
      HUNTER_PACKAGE_BASENAME
      "${HUNTER_PACKAGE_BASENAME}-${HUNTER_INSTALL_TAG}"
  )

  # Update variants
  unset(HUNTER_PACKAGE_VARIANTS)
  string(
      COMPARE
      EQUAL
      "${HUNTER_DOWNLOAD_SCHEME}"
      "url_sha1_boost_ios_library"
      is_ios
  )
  if(is_ios)
    set(HUNTER_PACKAGE_VARIANTS ios ios_sim ios_universal)
  endif()

  string(
      COMPARE
      EQUAL
      "${HUNTER_DOWNLOAD_SCHEME}"
      "url_sha1_release_debug"
      is_release_debug
  )
  if(is_release_debug)
    set(HUNTER_PACKAGE_VARIANTS release debug)
  endif()

  string(
      COMPARE
      EQUAL
      "${HUNTER_DOWNLOAD_SCHEME}"
      "url_sha1_openssl_ios"
      is_openssl_ios
  )
  if(is_openssl_ios)
    set(
        HUNTER_PACKAGE_VARIANTS
        ${IPHONEOS_ARCHS}
        ${IPHONESIMULATOR_ARCHS}
        ios_universal
    )
  endif()

  # print info before start generation/run
  hunter_status_debug("Add package: ${HUNTER_PACKAGE_NAME}")
  if(HUNTER_PACKAGE_COMPONENT)
    hunter_status_debug("Component: ${HUNTER_PACKAGE_COMPONENT}")
  endif()
  hunter_status_debug("Install tag: ${HUNTER_INSTALL_TAG}")
  if(HUNTER_PACKAGE_VARIANTS)
    hunter_status_debug("Variants: [${HUNTER_PACKAGE_VARIANTS}]")
  endif()
  hunter_status_debug("Url: ${HUNTER_PACKAGE_URL}")
  hunter_status_debug("SHA1: ${HUNTER_PACKAGE_SHA1}")

  if(NOT HUNTER_DOWNLOAD_SCHEME)
    hunter_fatal_error("No download scheme")
  endif()

  set(
      download_scheme
      "${HUNTER_ROOT}/cmake/schemes/${HUNTER_DOWNLOAD_SCHEME}.cmake.in"
  )
  if(NOT EXISTS "${download_scheme}")
    hunter_fatal_error("Download scheme not found")
  endif()

  # Optimization:
  #     Check run needed. If 'Stamp/<name-...>/<name-...>-install' file
  #     detected, no need to generate/run project
  set(need_to_run FALSE)
  string(COMPARE EQUAL "${HUNTER_CMAKE_GENERATOR}" "Xcode" is_xcode)
  if(HUNTER_PACKAGE_VARIANTS)
    foreach(variant ${HUNTER_PACKAGE_VARIANTS})
      set(x "${HUNTER_PACKAGE_BASENAME}-${variant}")
      if(is_xcode)
        set(x "${HUNTER_BASE}/Stamp/${x}/Debug-iphoneos/${x}-install")
      else()
        set(x "${HUNTER_BASE}/Stamp/${x}/${x}-install")
      endif()
      if(NOT EXISTS "${x}")
        set(need_to_run TRUE)
      endif()
    endforeach()
  else()
    set(x "${HUNTER_PACKAGE_BASENAME}")
    if(is_xcode)
      set(x "${HUNTER_BASE}/Stamp/${x}/Debug-iphoneos/${x}-install")
    else()
      set(x "${HUNTER_BASE}/Stamp/${x}/${x}-install")
    endif()
    if(NOT EXISTS "${x}")
      set(need_to_run TRUE)
    endif()
  endif()

  if(NOT need_to_run)
    hunter_status_debug("Skip generate/run (already installed)")
    return()
  endif()

  configure_file(
      "${download_scheme}"
      "${h_work_dir}/CMakeLists.txt"
      @ONLY
  )

  # support for custom cmake generators
  if(HUNTER_CMAKE_GENERATOR)
    set(h_generator "-G${HUNTER_CMAKE_GENERATOR}")
  else()
    # use default
    set(h_generator)
  endif()

  hunter_status_debug("Run generate")

  # Configure and build download project
  execute_process(
      COMMAND
      ${CMAKE_COMMAND}
      "-DCMAKE_TOOLCHAIN_FILE=${toolchain_wrapper}"
      "-DHUNTER_STATUS_DEBUG=${HUNTER_STATUS_DEBUG}"
      ${h_generator}
      ${verbose_makefile}
      "./"
      WORKING_DIRECTORY
      ${h_work_dir}
      RESULT_VARIABLE
      h_generate_result
  )

  if(NOT ${h_generate_result} EQUAL 0)
    hunter_fatal_error("generate step failed")
  endif()

  hunter_status_debug("Run build")

  execute_process(
      COMMAND
      ${CMAKE_COMMAND} --build "./"
      WORKING_DIRECTORY
      ${h_work_dir}
      RESULT_VARIABLE
      h_build_result
  )

  if(NOT ${h_build_result} EQUAL 0)
    hunter_fatal_error("build step failed")
  endif()

  if(NOT HUNTER_STATUS_DEBUG)
    # clean-up
    file(REMOVE_RECURSE "${h_work_dir}")
  endif()
endfunction()
