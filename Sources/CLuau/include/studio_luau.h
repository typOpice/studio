// A small C surface over Luau, so Swift can drive the VM without C++ interop.
//
// Deliberately thin: pushing and reading values is done through the Lua stack the
// same way the rest of the world writes Lua bindings, and everything above that —
// marshalling, error formatting, the object model — lives in Swift.
#ifndef STUDIO_LUAU_H
#define STUDIO_LUAU_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct StudioLua StudioLua;

/// Value kinds, matching Lua's own type tags for the ones we care about.
enum {
    STUDIO_LUA_NIL = 0,
    STUDIO_LUA_BOOLEAN = 1,
    STUDIO_LUA_NUMBER = 2,
    STUDIO_LUA_STRING = 3,
    STUDIO_LUA_TABLE = 4,
    STUDIO_LUA_FUNCTION = 5,
    STUDIO_LUA_OTHER = 6
};

/// Called for every `__studio_invoke(...)`. Arguments are on the stack at 1..argc;
/// push results and return how many were pushed.
typedef int (*StudioInvokeFn)(void *context, StudioLua *vm, int argc);

// MARK: - The debugger
//
// Breakpoints are Luau's own (lua_breakpoint patches a line's first instruction), set
// on the chunks the host keeps. When one is reached `pause` is called from inside the
// VM, which is frozen — every script — until it returns; meanwhile the
// studio_lua_debug_* calls read where it stopped. The watchdog's clock stops too.

/// Reached a breakpoint at `line`.
typedef void (*StudioPauseFn)(void *context, StudioLua *vm, int line);
/// A chunk loaded into `environment` (a name from studio_lua_make_environment, or "");
/// its function is on top of the stack, for studio_lua_keep_chunk.
typedef void (*StudioLoadedFn)(void *context, StudioLua *vm, const char *environment);

void studio_lua_set_debugger(StudioLua *vm, StudioPauseFn pause, StudioLoadedFn loaded);
/// Keeps the chunk on top of the stack under `key` (a script's id), for breakpoints.
void studio_lua_keep_chunk(StudioLua *vm, const char *key);
/// Sets or clears a breakpoint on a line of every chunk kept under `key`: the next
/// line with code on it, which is returned (-1 for none).
int studio_lua_set_breakpoint(StudioLua *vm, const char *key, int line, int enabled);
/// A breakpoint on every line of every kept chunk, or none: how stepping stops.
void studio_lua_break_everywhere(StudioLua *vm, int enabled);

/// While paused: the thread that stopped (to tell threads apart), and how many frames deep.
const void *studio_lua_debug_thread(StudioLua *vm);
int studio_lua_debug_depth(StudioLua *vm);
/// A frame of the paused thread, 0 where it stopped: the environment of its function
/// ("" for the library's own), the function's name ("" for none) and its line. 0 past the last.
int studio_lua_debug_frame(StudioLua *vm, int level, const char **environment, const char **function, int *line);
/// A frame's locals, then its upvalues, each described; returns how many.
int studio_lua_debug_variables(StudioLua *vm, int level);
void studio_lua_debug_variable(StudioLua *vm, int index, const char **name, const char **kind,
                               const char **type, const char **value);
/// How a variable (or field) is reached in an expression: a name, `.key`, `["key"]`, `[1]`;
/// "" when it can't be (a table as a key).
const char *studio_lua_debug_variable_path(StudioLua *vm, int index);
/// Evaluates an expression in a frame, seeing its locals and upvalues, then the script's
/// globals: 1 and the result described, or 0 and why (studio_lua_debug_evaluation).
int studio_lua_debug_evaluate(StudioLua *vm, int level, const char *expression);
void studio_lua_debug_evaluation(StudioLua *vm, const char **type, const char **value, const char **error, int *truthy);
/// A logpoint's message: an expression list worked out in a frame, written as print
/// writes its arguments (the evaluation's value), or 0 and why.
int studio_lua_debug_log(StudioLua *vm, int level, const char *expression);
/// A table an expression comes to: up to `most` of its entries as variables (read with
/// studio_lua_debug_variable and _path); -1 if it isn't a table or fails.
int studio_lua_debug_fields(StudioLua *vm, int level, const char *expression, int most);

StudioLua *studio_lua_new(void *context, StudioInvokeFn invoke);
void studio_lua_free(StudioLua *vm);

/// Freezes the standard libraries so scripts cannot redefine them.
void studio_lua_sandbox(StudioLua *vm);

/// Aborts any script that runs longer than this. 0 disables the limit.
void studio_lua_set_timeout(StudioLua *vm, double seconds);

/// Compiles and runs a chunk to completion. `environment` names a table created with
/// studio_lua_make_environment, or NULL for the shared globals. Returns 0 on
/// success; the message is in studio_lua_last_error.
int studio_lua_run(StudioLua *vm, const char *chunkName, const char *source,
                   const char *environment);

/// Compiles a chunk and hands the resulting function to the global Luau function
/// `__studio_spawn`, which runs it inside a coroutine so it may yield. Returns 0 if
/// it compiled and `__studio_spawn` returned true.
int studio_lua_spawn(StudioLua *vm, const char *chunkName, const char *source,
                     const char *environment);

/// Per-script globals: a table whose misses fall through to the shared globals.
/// Kept in the registry rather than the globals table, which is read-only once
/// the VM is sandboxed.
void studio_lua_make_environment(StudioLua *vm, const char *name);
void studio_lua_drop_environment(StudioLua *vm, const char *name);

/// Calls a global function with a single number argument. Returns 0 on success.
int studio_lua_call_number(StudioLua *vm, const char *name, double argument);

const char *studio_lua_last_error(StudioLua *vm);

/// Bytes the VM currently holds, for reporting.
size_t studio_lua_memory(StudioLua *vm);

// MARK: - Stack access, used from inside an invoke callback

int studio_lua_type(StudioLua *vm, int index);
int studio_lua_top(StudioLua *vm);
double studio_lua_to_number(StudioLua *vm, int index);
int studio_lua_to_boolean(StudioLua *vm, int index);
/// Valid until the value is popped; copy it straight away.
const char *studio_lua_to_string(StudioLua *vm, int index);
int studio_lua_length(StudioLua *vm, int index);
/// Pushes t[n] (1-based) from the table at `index`.
void studio_lua_get_index(StudioLua *vm, int index, int n);
/// Pushes t[key] from the table at `index`.
void studio_lua_get_field(StudioLua *vm, int index, const char *key);
void studio_lua_pop(StudioLua *vm, int count);

void studio_lua_push_nil(StudioLua *vm);
void studio_lua_push_number(StudioLua *vm, double value);
void studio_lua_push_boolean(StudioLua *vm, int value);
void studio_lua_push_string(StudioLua *vm, const char *value);
void studio_lua_push_table(StudioLua *vm, int arrayCount);
/// Pops a value and stores it as t[n] in the table just below it.
void studio_lua_set_index(StudioLua *vm, int n);

#ifdef __cplusplus
}
#endif

#endif
