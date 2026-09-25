# Jolt Physics, vendored

`Jolt/` is the library directory of **Jolt Physics v5.6.0** by Jorrit Rouwe
(https://github.com/jrouwe/JoltPhysics, tag `v5.6.0`), copied verbatim under the MIT
licence in `LICENSE-jolt.txt`. Nothing in it is modified.

The GPU compute backends (`Jolt/Compute/MTL`, `VK`, `DX12`), the HLSL shaders and the
CMake/natvis files are excluded from the build in `Package.swift`; the Studio uses only
the CPU rigid-body physics, single-threaded.

`include/studio_jolt.h` and `shim/studio_jolt.cpp` are ours: a small C-linkage API so
Swift can drive Jolt without C++ interop, as `CLuau` does for Luau.

To update: replace `Jolt/` with the new release's `Jolt/` directory, rebuild, and run
`swift run StudioApp --selftest` — `PhysicsSelfTest` checks the behaviour the Studio
relies on.
