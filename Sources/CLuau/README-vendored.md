# Vendored Luau

Luau 0.640 (https://luau.org, https://github.com/luau-lang/luau), MIT licensed — see
`LICENSE-luau.txt`. `luau/` holds the `VM`, `Compiler`, `Ast`, `Common`, `Analysis`, `Config` and `EqSat` trees
copied verbatim from https://github.com/luau-lang/luau/releases/tag/0.640.
`CodeGen` (the JIT) is left out. Analysis is editor-only; annotations remain
erased by the runtime compiler. The analysis bridge lives in
`include/studio_luau_analysis.h` and `shim/studio_luau_analysis.cpp`.

Nothing under `luau/` is modified. To update, drop in a newer release's trees.

`include/studio_luau.h` and `shim/studio_luau.cpp` are ours: a C-linkage surface so
Swift can drive the VM without C++ interop.
