# GLFW rotating cube (legacy OpenGL)

This sample opens a GLFW window and draws a rotating cube using legacy OpenGL immediate mode. It lives alongside the Metal samples for contrast and quick experiments.

## Prerequisites (macOS)

```zsh
brew install glfw pkg-config
```

## Build options

- CMake (recommended):

```zsh
cmake -S .. -B ../build
cmake --build ../build --target simple_glfw_cube -- -j4
../build/simple_glfw_cube
```

- Direct compile with pkg-config (portable):

```zsh
clang++ -std=c++17 ../src/main.cpp -o ../build/simple_glfw_cube \
  $(pkg-config --cflags glfw3) \
  $(pkg-config --libs glfw3) \
  -framework OpenGL -framework Cocoa -framework IOKit -framework CoreVideo
```

- Direct compile with Homebrew prefix (if pkg-config is unavailable):

```zsh
BREW_PREFIX=$(brew --prefix)
clang++ -std=c++17 \
  -I"$BREW_PREFIX"/include \
  -L"$BREW_PREFIX"/lib \
  ../src/main.cpp -lglfw \
  -framework Cocoa -framework OpenGL -framework IOKit -framework CoreVideo \
  -o ../build/simple_glfw_cube
```

## Troubleshooting

- If you see `fatal error: 'GLFW/glfw3.h' file not found`, ensure the include path matches your Homebrew prefix (often `/opt/homebrew` on Apple Silicon), or prefer the pkg-config command.
- On macOS, remember to link the Apple frameworks listed above when compiling manually.
