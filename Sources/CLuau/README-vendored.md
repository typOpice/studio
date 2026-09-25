# Vendored Luau

Luau 0.640 (https://luau.org, https://github.com/luau-lang/luau), MIT licensed — see
`LICENSE-luau.txt`. `luau/` holds the `VM`, `Compiler`, `Ast` and `Common` trees
copied verbatim; `Analysis` (the type checker) and `CodeGen` (the JIT) are left out,
so type annotations parse and are ignored rather than checked.

Nothing under `luau/` is modified. To update, drop in a newer release's trees.

`include/studio_luau.h` and `shim/studio_luau.cpp` are ours: a C-linkage surface so
Swift can drive the VM without C++ interop.
