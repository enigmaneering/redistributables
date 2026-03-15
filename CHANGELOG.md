# Changelog - External Vendor Tools

## [v0.0.43] - Unreleased

### Fixed
- **Version mismatch in Go library**: Changed `defaultVersion` from `v0.042` to `v0.0.42` to match actual GitHub release tags
- **DXC runtime library missing on macOS/Linux**:
  - DXC binary requires `libdxcompiler.dylib` (macOS) or `libdxcompiler.so` (Linux) at runtime
  - Previous release only packaged the `dxc` binary without the required shared library
  - Now packages both `dxc` binary and `libdxcompiler` library
  - Added `lib/` directory to package structure
  - Updated macOS binary rpath from `@rpath` to `@executable_path/../lib` for proper dylib loading

### Changed
- Build script now automatically builds `dxcompiler` as a dependency of `dxc`
- Package structure changed:
  - `bin/dxc` - DXC compiler binary
  - `lib/libdxcompiler.dylib` (macOS) or `lib/libdxcompiler.so` (Linux) - Required runtime library
- Added rpath fix for macOS using `install_name_tool`
- Added verification output showing library dependencies after build

## [v0.0.42] - 2024-03-14

Initial release with pre-built binaries for:
- glslang (GLSL → SPIRV compiler)
- SPIRV-Cross (SPIRV transpiler)
- DXC (HLSL → SPIRV compiler) - **Note: macOS/Linux builds missing libdxcompiler**

Platforms:
- darwin-arm64, darwin-amd64
- linux-arm64, linux-amd64
- windows-arm64, windows-amd64

Known Issues:
- Go library uses wrong version string `v0.042` instead of `v0.0.42`
- DXC missing runtime library on macOS/Linux
