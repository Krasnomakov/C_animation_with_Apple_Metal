cmake_minimum_required(VERSION 3.10)
project(simple_glfw_cube)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Try to find GLFW with CMake package config (Homebrew provides this).
find_package(glfw3 CONFIG)

if (glfw3_FOUND)
	message(STATUS "Found glfw3 via CMake config")
	set(GLFW_LIBRARIES glfw)
else()
	# Fallback to pkg-config if available
	find_package(PkgConfig)
	if (PKG_CONFIG_FOUND)
		pkg_search_module(GLFW REQUIRED glfw3)
		include_directories(${GLFW_INCLUDE_DIRS})
		set(GLFW_LIBRARIES ${GLFW_LIBRARIES})
	else()
		message(WARNING "Could not find glfw3 via CMake config or pkg-config. You may need to install GLFW (e.g., brew install glfw) or set GLFW3_DIR to the installation directory.")
	endif()
endif()

find_package(OpenGL REQUIRED)

add_executable(simple_glfw_cube src/main.cpp)
if (glfw3_FOUND)
	target_link_libraries(simple_glfw_cube PRIVATE glfw ${OPENGL_LIBRARIES})
else()
	target_link_libraries(simple_glfw_cube PRIVATE ${GLFW_LIBRARIES} ${OPENGL_LIBRARIES})
endif()

# Metal-based sample (macOS only)
if(APPLE)
	enable_language(OBJCXX)
	add_executable(metal_cube
		src/metal_main.mm
		src/MetalRenderer.mm
		src/MetalRenderer.h
	)
	target_compile_definitions(metal_cube PRIVATE __APPLE__)
	target_link_libraries(metal_cube PRIVATE "-framework Cocoa" "-framework Metal" "-framework MetalKit")
endif()

if(APPLE)
	# Metal maze target
	add_executable(metal_maze
		src/metal_maze_main.mm
		src/MetalMazeRenderer.mm
		src/MetalMazeRenderer.h
	)
	target_compile_definitions(metal_maze PRIVATE __APPLE__)
	target_link_libraries(metal_maze PRIVATE "-framework Cocoa" "-framework Metal" "-framework MetalKit")
endif()

if(APPLE)
    # Metal room (single AABB room and bouncing sphere)
    add_executable(metal_room
        src/maze/metal_room_main.mm
        src/maze/MetalRoomRenderer.mm
        src/maze/MetalRoomRenderer.h
    )
    target_compile_definitions(metal_room PRIVATE __APPLE__)
    target_link_libraries(metal_room PRIVATE "-framework Cocoa" "-framework Metal" "-framework MetalKit")
endif()

# ------------------------------
# Metal compute console samples
# ------------------------------
if(APPLE)
	enable_language(OBJCXX)

	# Vector add compute sample
	add_executable(metal_compute_add
		src/compute/metal_compute_add.mm
	)
	target_compile_definitions(metal_compute_add PRIVATE __APPLE__ SOURCE_ROOT_DIR="${CMAKE_SOURCE_DIR}")
	target_link_libraries(metal_compute_add PRIVATE "-framework Metal" "-framework Foundation")

	# Parallel reduction (sum) compute sample
	add_executable(metal_compute_reduce
		src/compute/metal_compute_reduce.mm
	)
	target_compile_definitions(metal_compute_reduce PRIVATE __APPLE__ SOURCE_ROOT_DIR="${CMAKE_SOURCE_DIR}")
	target_link_libraries(metal_compute_reduce PRIVATE "-framework Metal" "-framework Foundation")
endif()

# ------------------------------
# Minimal triangle renderer
# ------------------------------
if(APPLE)
	add_executable(metal_triangle
		src/triangle/metal_triangle.mm
	)
	target_compile_definitions(metal_triangle PRIVATE __APPLE__)
	target_link_libraries(metal_triangle PRIVATE "-framework Cocoa" "-framework Metal" "-framework MetalKit" "-framework QuartzCore")
endif()
