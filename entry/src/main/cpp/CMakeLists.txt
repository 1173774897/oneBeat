cmake_minimum_required(VERSION 3.5.0)
project(onebeat_recording)
set(CMAKE_CXX_STANDARD 17)
add_library(onebeat_recording SHARED recording_native.cpp)
# Keep bounded offline DSP efficient even in device-debug builds; capture and
# playback callbacks must not compete with an unoptimized echo fit worker.
target_compile_options(onebeat_recording PRIVATE -Wall -Wextra -O2)
target_link_libraries(onebeat_recording PUBLIC libace_napi.z.so libnative_avscreen_capture.so
  libnative_media_core.so libnative_media_venc.so libnative_media_acodec.so
  libnative_media_avmuxer.so libnative_media_avdemuxer.so libnative_media_avsource.so
  libnative_media_codecbase.so libnative_window.so libohaudio.so)
