if(NOT DEFINED DEST_BASESET_DIR OR DEST_BASESET_DIR STREQUAL "")
    message(FATAL_ERROR "DEST_BASESET_DIR is required")
endif()

if(NOT DEFINED WORK_DIR OR WORK_DIR STREQUAL "")
    message(FATAL_ERROR "WORK_DIR is required")
endif()

# Xcode can pass literal ${EFFECTIVE_PLATFORM_NAME} in path arguments.
# Resolve it from the environment when available.
if(DEST_BASESET_DIR MATCHES "\\$\\{EFFECTIVE_PLATFORM_NAME\\}" AND DEFINED ENV{EFFECTIVE_PLATFORM_NAME})
    string(REPLACE "\${EFFECTIVE_PLATFORM_NAME}" "$ENV{EFFECTIVE_PLATFORM_NAME}" DEST_BASESET_DIR "${DEST_BASESET_DIR}")
endif()

file(MAKE_DIRECTORY "${DEST_BASESET_DIR}")
file(MAKE_DIRECTORY "${WORK_DIR}")

# If a complete original TTD set is present, do not fetch OpenGFX.
set(_has_original_set FALSE)
if(
    (EXISTS "${DEST_BASESET_DIR}/TRG1.GRF"  AND EXISTS "${DEST_BASESET_DIR}/TRGI.GRF"  AND EXISTS "${DEST_BASESET_DIR}/TRGC.GRF"  AND EXISTS "${DEST_BASESET_DIR}/TRGH.GRF"  AND EXISTS "${DEST_BASESET_DIR}/TRGT.GRF") OR
    (EXISTS "${DEST_BASESET_DIR}/TRG1R.GRF" AND EXISTS "${DEST_BASESET_DIR}/TRGIR.GRF" AND EXISTS "${DEST_BASESET_DIR}/TRGCR.GRF" AND EXISTS "${DEST_BASESET_DIR}/TRGHR.GRF" AND EXISTS "${DEST_BASESET_DIR}/TRGTR.GRF")
)
    set(_has_original_set TRUE)
endif()

if(_has_original_set)
    message(STATUS "[iOS] Original TTD graphics detected in bundle; skipping OpenGFX fetch")
    return()
endif()

if(EXISTS "${DEST_BASESET_DIR}/opengfx.obg")
    message(STATUS "[iOS] OpenGFX already present in bundle")
    return()
endif()

set(_cache_dir "${WORK_DIR}/opengfx-dist")
set(_zip_file "${WORK_DIR}/opengfx-all.zip")
set(_latest_page "${WORK_DIR}/opengfx-latest.html")

if(NOT EXISTS "${_cache_dir}/opengfx.obg")
    file(DOWNLOAD
        "https://www.openttd.org/downloads/opengfx-releases/latest"
        "${_latest_page}"
        STATUS _latest_status
        TLS_VERIFY ON
        SHOW_PROGRESS
    )
    list(GET _latest_status 0 _latest_code)

    if(NOT _latest_code EQUAL 0)
        message(WARNING "[iOS] Could not query latest OpenGFX release page (${_latest_status}); app may fail at runtime without a graphics set")
        return()
    endif()

    file(READ "${_latest_page}" _latest_html)
    string(REGEX MATCH "https://cdn\\.openttd\\.org/opengfx-releases/[0-9.]+/opengfx-[0-9.]+-all\\.zip" _zip_url "${_latest_html}")
    if(_zip_url STREQUAL "")
        set(_zip_url "https://cdn.openttd.org/opengfx-releases/8.0/opengfx-8.0-all.zip")
        message(WARNING "[iOS] Could not parse latest OpenGFX URL; falling back to ${_zip_url}")
    endif()

    file(DOWNLOAD
        "${_zip_url}"
        "${_zip_file}"
        STATUS _zip_status
        TLS_VERIFY ON
        SHOW_PROGRESS
    )
    list(GET _zip_status 0 _zip_code)
    if(NOT _zip_code EQUAL 0)
        message(WARNING "[iOS] Failed to download OpenGFX archive (${_zip_status}); app may fail at runtime without a graphics set")
        return()
    endif()

    execute_process(
        COMMAND "${CMAKE_COMMAND}" -E tar xf "${_zip_file}" --format=zip
        WORKING_DIRECTORY "${WORK_DIR}"
        RESULT_VARIABLE _unzip_result
    )
    if(NOT _unzip_result EQUAL 0)
        message(WARNING "[iOS] Failed to unpack OpenGFX ZIP archive; app may fail at runtime without a graphics set")
        return()
    endif()

    file(GLOB _tar_files "${WORK_DIR}/opengfx-*.tar")
    list(LENGTH _tar_files _tar_count)
    if(_tar_count EQUAL 0)
        message(WARNING "[iOS] OpenGFX ZIP did not contain a tar archive; app may fail at runtime without a graphics set")
        return()
    endif()
    list(GET _tar_files 0 _tar_file)

    execute_process(
        COMMAND "${CMAKE_COMMAND}" -E tar xf "${_tar_file}"
        WORKING_DIRECTORY "${WORK_DIR}"
        RESULT_VARIABLE _untar_result
    )
    if(NOT _untar_result EQUAL 0)
        message(WARNING "[iOS] Failed to unpack OpenGFX tar archive; app may fail at runtime without a graphics set")
        return()
    endif()

    file(GLOB _extract_dirs "${WORK_DIR}/opengfx-*")
    set(_source_dir "")
    foreach(_candidate IN LISTS _extract_dirs)
        if(IS_DIRECTORY "${_candidate}" AND EXISTS "${_candidate}/opengfx.obg")
            set(_source_dir "${_candidate}")
            break()
        endif()
    endforeach()

    if(_source_dir STREQUAL "")
        message(WARNING "[iOS] Could not locate unpacked OpenGFX data; app may fail at runtime without a graphics set")
        return()
    endif()

    file(MAKE_DIRECTORY "${_cache_dir}")
    file(GLOB _source_files
        "${_source_dir}/opengfx.obg"
        "${_source_dir}/ogfx*.grf"
        "${_source_dir}/readme.txt"
        "${_source_dir}/license.txt"
        "${_source_dir}/changelog.txt"
    )
    foreach(_file IN LISTS _source_files)
        execute_process(
            COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${_file}" "${_cache_dir}"
            RESULT_VARIABLE _copy_result
        )
        if(NOT _copy_result EQUAL 0)
            message(WARNING "[iOS] Failed to cache OpenGFX file: ${_file}")
        endif()
    endforeach()
endif()

if(NOT EXISTS "${_cache_dir}/opengfx.obg")
    message(WARNING "[iOS] OpenGFX cache is incomplete; app may fail at runtime without a graphics set")
    return()
endif()

file(GLOB _cached_files
    "${_cache_dir}/opengfx.obg"
    "${_cache_dir}/ogfx*.grf"
    "${_cache_dir}/readme.txt"
    "${_cache_dir}/license.txt"
    "${_cache_dir}/changelog.txt"
)
foreach(_file IN LISTS _cached_files)
    execute_process(
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${_file}" "${DEST_BASESET_DIR}"
        RESULT_VARIABLE _bundle_copy_result
    )
    if(NOT _bundle_copy_result EQUAL 0)
        message(WARNING "[iOS] Failed to copy OpenGFX file into app bundle: ${_file}")
    endif()
endforeach()

if(EXISTS "${DEST_BASESET_DIR}/opengfx.obg")
    message(STATUS "[iOS] OpenGFX bundled into ${DEST_BASESET_DIR}")
else()
    message(WARNING "[iOS] OpenGFX could not be bundled; app may fail at runtime without a graphics set")
endif()
