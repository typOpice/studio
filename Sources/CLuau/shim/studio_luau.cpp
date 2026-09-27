#include "studio_luau.h"

#include "lua.h"
#include "lualib.h"
#include "luacode.h"

#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

struct StudioLuaImpl {
    lua_State *state = nullptr;
    /// The thread currently inside an invoke callback. Coroutines have their own
    /// stacks, so arguments must be read from — and results pushed onto — the
    /// thread that made the call, not the main one.
    lua_State *current = nullptr;
    void *context = nullptr;
    StudioInvokeFn invoke = nullptr;
    std::string lastError;

    double timeout = 0;
    std::chrono::steady_clock::time_point deadline;
    bool timing = false;

    // The debugger.
    StudioPauseFn pause = nullptr;
    StudioLoadedFn loaded = nullptr;
    /// The thread stopped at a breakpoint, while it is.
    lua_State *paused = nullptr;
    /// Environments by their table, to tell whose code a frame is.
    std::unordered_map<const void *, std::string> environments;
    std::string frameEnvironment, frameFunction;
    /// `path`: how to reach it in a watch expression (a local's name, `.key`, `[1]`); "" for no way.
    struct Variable { std::string name, kind, type, value, path; };
    std::vector<Variable> variables;
    /// The last expression evaluated while paused: what it came to, or why not.
    struct Evaluation { std::string type, value, error; bool truthy = false; };
    Evaluation evaluation;
};

StudioLuaImpl *impl(StudioLua *vm) { return reinterpret_cast<StudioLuaImpl *>(vm); }
StudioLua *opaque(StudioLuaImpl *vm) { return reinterpret_cast<StudioLua *>(vm); }

/// The wrapper is reachable from any thread of the VM through the callbacks'
/// userdata. It must not go through the Lua stack: the interrupt hook runs at
/// arbitrary safepoints where the stack may have no room to push anything.
StudioLuaImpl *selfFor(lua_State *L) {
    return static_cast<StudioLuaImpl *>(lua_callbacks(L)->userdata);
}

int invokeTrampoline(lua_State *L) {
    StudioLuaImpl *self = selfFor(L);
    if (self == nullptr || self->invoke == nullptr) {
        return 0;
    }
    lua_State *previous = self->current;
    self->current = L;
    // The engine's work for the script (building a path grid, say) isn't the script's
    // own time: the watchdog's deadline moves on by however long the call took. A loop
    // in the script still runs out of time, since the deadline only moves once the call
    // is back.
    auto started = std::chrono::steady_clock::now();
    int results = self->invoke(self->context, opaque(self), lua_gettop(L));
    if (self->timing) {
        self->deadline += std::chrono::steady_clock::now() - started;
    }
    self->current = previous;
    return results;
}

/// Runs at loop back-edges and calls; aborts a script that has overstayed.
void interruptHook(lua_State *L, int gc) {
    if (gc >= 0) {
        return;   // a garbage-collection step, not a safepoint we care about
    }
    StudioLuaImpl *self = selfFor(L);
    if (self == nullptr || !self->timing) {
        return;
    }
    if (std::chrono::steady_clock::now() < self->deadline) {
        return;
    }
    self->timing = false;

    // Say where it was stopped: an endless loop is found by its line number.
    std::string message = "script ran for too long and was stopped";
    lua_Debug ar;
    if (lua_getinfo(L, 0, "sl", &ar) && ar.currentline > 0) {
        message = std::string(ar.short_src) + ":" + std::to_string(ar.currentline) + ": " + message;
    }
    lua_rawcheckstack(L, 1);
    lua_pushstring(L, message.c_str());
    lua_error(L);
}

void beginTiming(StudioLuaImpl *self) {
    if (self->timeout <= 0) {
        self->timing = false;
        return;
    }
    self->timing = true;
    self->deadline = std::chrono::steady_clock::now()
        + std::chrono::milliseconds(static_cast<long long>(self->timeout * 1000));
}

/// A breakpoint: the host decides what happens, with the VM frozen and the watchdog's
/// clock stopped. Breakpoints reached while it's deciding (a value's __tostring, say)
/// are passed over.
void debugBreakHook(lua_State *L, lua_Debug *ar) {
    StudioLuaImpl *self = selfFor(L);
    if (self == nullptr || self->pause == nullptr || self->paused != nullptr) {
        return;
    }
    bool wasTiming = self->timing;
    auto left = self->deadline - std::chrono::steady_clock::now();
    self->timing = false;
    self->paused = L;
    self->pause(self->context, opaque(self), ar->currentline);
    self->paused = nullptr;
    if (wasTiming) {
        self->deadline = std::chrono::steady_clock::now() + left;
        self->timing = true;
    }
}

/// Called from the Luau scheduler before each callback or resumed thread, so every
/// one gets a fresh time budget instead of sharing the frame's.
int armTrampoline(lua_State *L) {
    StudioLuaImpl *self = selfFor(L);
    if (self != nullptr) {
        beginTiming(self);
    }
    return 0;
}

}  // namespace

extern "C" {

StudioLua *studio_lua_new(void *context, StudioInvokeFn invoke) {
    StudioLuaImpl *self = new StudioLuaImpl();
    self->context = context;
    self->invoke = invoke;

    self->state = luaL_newstate();
    if (self->state == nullptr) {
        delete self;
        return nullptr;
    }
    luaL_openlibs(self->state);

    lua_callbacks(self->state)->userdata = self;

    lua_pushcfunction(self->state, invokeTrampoline, "__studio_invoke");
    lua_setglobal(self->state, "__studio_invoke");
    lua_pushcfunction(self->state, armTrampoline, "__studio_arm");
    lua_setglobal(self->state, "__studio_arm");

    lua_callbacks(self->state)->interrupt = interruptHook;
    return opaque(self);
}

void studio_lua_free(StudioLua *vm) {
    StudioLuaImpl *self = impl(vm);
    if (self == nullptr) {
        return;
    }
    if (self->state != nullptr) {
        lua_close(self->state);
    }
    delete self;
}

void studio_lua_sandbox(StudioLua *vm) {
    luaL_sandbox(impl(vm)->state);
}

void studio_lua_set_timeout(StudioLua *vm, double seconds) {
    impl(vm)->timeout = seconds;
}

static std::string environmentKey(const char *name) { return std::string("__studio_env:") + name; }

void studio_lua_make_environment(StudioLua *vm, const char *name) {
    lua_State *L = impl(vm)->state;
    lua_newtable(L);
    impl(vm)->environments[lua_topointer(L, -1)] = name;

    // Fall through to the real globals for anything the script did not define.
    lua_newtable(L);
    lua_pushvalue(L, LUA_GLOBALSINDEX);
    lua_setfield(L, -2, "__index");
    lua_setmetatable(L, -2);

    lua_setfield(L, LUA_REGISTRYINDEX, environmentKey(name).c_str());
}

void studio_lua_drop_environment(StudioLua *vm, const char *name) {
    lua_State *L = impl(vm)->state;
    lua_getfield(L, LUA_REGISTRYINDEX, environmentKey(name).c_str());
    impl(vm)->environments.erase(lua_topointer(L, -1));
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_setfield(L, LUA_REGISTRYINDEX, environmentKey(name).c_str());
}

/// Compiles and loads a chunk, leaving its function on the stack. Returns 0 on success.
static int loadChunk(StudioLuaImpl *self, const char *chunkName, const char *source,
              const char *environment) {
    lua_State *L = self->state;
    self->lastError.clear();

    size_t bytecodeSize = 0;
    lua_CompileOptions options = {};
    options.optimizationLevel = 1;
    // 2: local and upvalue names too, for the debugger.
    options.debugLevel = 2;
    char *bytecode = luau_compile(source, std::strlen(source), &options, &bytecodeSize);
    if (bytecode == nullptr) {
        self->lastError = "could not compile the script";
        return 1;
    }

    int environmentIndex = 0;
    if (environment != nullptr) {
        lua_getfield(L, LUA_REGISTRYINDEX, environmentKey(environment).c_str());
        if (lua_istable(L, -1)) {
            environmentIndex = lua_gettop(L);
        } else {
            lua_pop(L, 1);
        }
    }

    int loaded = luau_load(L, chunkName, bytecode, bytecodeSize, environmentIndex);
    std::free(bytecode);

    if (loaded != 0) {
        const char *message = lua_tostring(L, -1);
        self->lastError = message != nullptr ? message : "could not load the script";
        lua_pop(L, 1);
        if (environmentIndex != 0) {
            lua_remove(L, environmentIndex);
        }
        return 1;
    }

    if (environmentIndex != 0) {
        lua_remove(L, environmentIndex);
    }
    if (self->loaded != nullptr) {
        int top = lua_gettop(L);
        self->loaded(self->context, opaque(self), environment != nullptr ? environment : "");
        lua_settop(L, top);
    }
    return 0;
}

int studio_lua_run(StudioLua *vm, const char *chunkName, const char *source,
                   const char *environment) {
    StudioLuaImpl *self = impl(vm);
    lua_State *L = self->state;
    if (loadChunk(self, chunkName, source, environment) != 0) {
        return 1;
    }

    beginTiming(self);
    int status = lua_pcall(L, 0, 0, 0);
    self->timing = false;

    if (status != 0) {
        const char *message = lua_tostring(L, -1);
        self->lastError = message != nullptr ? message : "the script stopped with an error";
        lua_pop(L, 1);
        return 1;
    }
    return 0;
}

int studio_lua_spawn(StudioLua *vm, const char *chunkName, const char *source,
                     const char *environment) {
    StudioLuaImpl *self = impl(vm);
    lua_State *L = self->state;
    if (loadChunk(self, chunkName, source, environment) != 0) {
        return 1;
    }

    lua_getglobal(L, "__studio_spawn");
    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 2);
        self->lastError = "__studio_spawn is not defined";
        return 1;
    }
    lua_insert(L, -2);   // __studio_spawn, chunk

    beginTiming(self);
    int status = lua_pcall(L, 1, 1, 0);
    self->timing = false;

    if (status != 0) {
        const char *message = lua_tostring(L, -1);
        self->lastError = message != nullptr ? message : "the script stopped with an error";
        lua_pop(L, 1);
        return 1;
    }
    int succeeded = lua_toboolean(L, -1);
    lua_pop(L, 1);
    return succeeded ? 0 : 1;
}

int studio_lua_call_number(StudioLua *vm, const char *name, double argument) {
    StudioLuaImpl *self = impl(vm);
    lua_State *L = self->state;
    self->lastError.clear();

    lua_getglobal(L, name);
    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 1);
        self->lastError = std::string(name) + " is not a function";
        return 1;
    }
    lua_pushnumber(L, argument);

    beginTiming(self);
    int status = lua_pcall(L, 1, 0, 0);
    self->timing = false;

    if (status != 0) {
        const char *message = lua_tostring(L, -1);
        self->lastError = message != nullptr ? message : "the script stopped with an error";
        lua_pop(L, 1);
        return 1;
    }
    return 0;
}

const char *studio_lua_last_error(StudioLua *vm) {
    return impl(vm)->lastError.c_str();
}

size_t studio_lua_memory(StudioLua *vm) {
    return static_cast<size_t>(lua_gc(impl(vm)->state, LUA_GCCOUNT, 0)) * 1024;
}

// MARK: - Stack access

static lua_State *stackOf(StudioLua *vm) {
    StudioLuaImpl *self = impl(vm);
    return self->current != nullptr ? self->current : self->state;
}

int studio_lua_type(StudioLua *vm, int index) {
    switch (lua_type(stackOf(vm), index)) {
    case LUA_TNIL: return STUDIO_LUA_NIL;
    case LUA_TBOOLEAN: return STUDIO_LUA_BOOLEAN;
    case LUA_TNUMBER: return STUDIO_LUA_NUMBER;
    case LUA_TSTRING: return STUDIO_LUA_STRING;
    case LUA_TTABLE: return STUDIO_LUA_TABLE;
    case LUA_TFUNCTION: return STUDIO_LUA_FUNCTION;
    default: return STUDIO_LUA_OTHER;
    }
}

int studio_lua_top(StudioLua *vm) { return lua_gettop(stackOf(vm)); }
double studio_lua_to_number(StudioLua *vm, int index) { return lua_tonumber(stackOf(vm), index); }
int studio_lua_to_boolean(StudioLua *vm, int index) { return lua_toboolean(stackOf(vm), index); }

const char *studio_lua_to_string(StudioLua *vm, int index) {
    lua_State *L = stackOf(vm);
    if (lua_type(L, index) == LUA_TSTRING) {
        return lua_tostring(L, index);
    }
    return nullptr;
}

int studio_lua_length(StudioLua *vm, int index) {
    return static_cast<int>(lua_objlen(stackOf(vm), index));
}

void studio_lua_get_index(StudioLua *vm, int index, int n) {
    lua_State *L = stackOf(vm);
    lua_rawgeti(L, index, n);
}

void studio_lua_get_field(StudioLua *vm, int index, const char *key) {
    lua_State *L = stackOf(vm);
    lua_getfield(L, index, key);
}

void studio_lua_pop(StudioLua *vm, int count) { lua_pop(stackOf(vm), count); }

void studio_lua_push_nil(StudioLua *vm) { lua_pushnil(stackOf(vm)); }
void studio_lua_push_number(StudioLua *vm, double value) { lua_pushnumber(stackOf(vm), value); }
void studio_lua_push_boolean(StudioLua *vm, int value) { lua_pushboolean(stackOf(vm), value); }
void studio_lua_push_string(StudioLua *vm, const char *value) { lua_pushstring(stackOf(vm), value); }

void studio_lua_push_table(StudioLua *vm, int arrayCount) {
    lua_createtable(stackOf(vm), arrayCount, 0);
}

void studio_lua_set_index(StudioLua *vm, int n) {
    lua_State *L = stackOf(vm);
    lua_rawseti(L, -2, n);
}

}  // extern "C"

// MARK: - The debugger

namespace {

const char *const chunksKey = "__studio_chunks";

/// The registry's table of kept chunks, by key, pushed.
void pushChunks(lua_State *L) {
    lua_getfield(L, LUA_REGISTRYINDEX, chunksKey);
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, LUA_REGISTRYINDEX, chunksKey);
    }
}

/// Every line of a function (on top of the stack) and those inside it.
void breakEveryLine(lua_State *L, int enabled) {
    int line = 0;
    while (line < 1000000) {
        int target = lua_breakpoint(L, -1, line, enabled);
        if (target < 0) {
            break;
        }
        line = target + 1;
    }
}

/// A value, as the library describes it (its type and a short text), or plainly.
void describe(StudioLuaImpl *self, lua_State *P, int index, std::string &type, std::string &text) {
    index = lua_absindex(P, index);
    lua_rawcheckstack(P, 4);
    lua_getglobal(P, "__studio_describe");
    if (lua_isfunction(P, -1)) {
        lua_pushvalue(P, index);
        // A moment for anything it runs (a __tostring), then the clock stops again.
        self->timing = true;
        self->deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(200);
        int status = lua_pcall(P, 1, 2, 0);
        self->timing = false;
        if (status == 0) {
            const char *kind = lua_tostring(P, -2), *shown = lua_tostring(P, -1);
            type = kind != nullptr ? kind : luaL_typename(P, index);
            text = shown != nullptr ? shown : "";
            lua_pop(P, 2);
            return;
        }
        lua_pop(P, 1);
    } else {
        lua_pop(P, 1);
    }
    type = luaL_typename(P, index);
    size_t length = 0;
    const char *plain = luaL_tolstring(P, index, &length);
    text = plain != nullptr ? std::string(plain, length) : "";
    lua_pop(P, 1);
}

}  // namespace

extern "C" {

void studio_lua_set_debugger(StudioLua *vm, StudioPauseFn pause, StudioLoadedFn loaded) {
    StudioLuaImpl *self = impl(vm);
    self->pause = pause;
    self->loaded = loaded;
    lua_callbacks(self->state)->debugbreak = pause != nullptr ? debugBreakHook : nullptr;
}

void studio_lua_keep_chunk(StudioLua *vm, const char *key) {
    lua_State *L = impl(vm)->state;
    int chunk = lua_gettop(L);
    pushChunks(L);
    lua_getfield(L, -1, key);
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_setfield(L, -3, key);
    }
    lua_pushvalue(L, chunk);
    lua_rawseti(L, -2, lua_objlen(L, -2) + 1);
    lua_pop(L, 2);
}

int studio_lua_set_breakpoint(StudioLua *vm, const char *key, int line, int enabled) {
    lua_State *L = impl(vm)->state;
    int landed = -1;
    pushChunks(L);
    lua_getfield(L, -1, key);
    if (lua_istable(L, -1)) {
        int count = lua_objlen(L, -1);
        for (int i = 1; i <= count; ++i) {
            lua_rawgeti(L, -1, i);
            int target = lua_breakpoint(L, -1, line, enabled);
            if (landed < 0) {
                landed = target;
            }
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 2);
    return landed;
}

void studio_lua_break_everywhere(StudioLua *vm, int enabled) {
    lua_State *L = impl(vm)->state;
    pushChunks(L);
    lua_pushnil(L);
    while (lua_next(L, -2) != 0) {
        if (lua_istable(L, -1)) {
            int count = lua_objlen(L, -1);
            for (int i = 1; i <= count; ++i) {
                lua_rawgeti(L, -1, i);
                breakEveryLine(L, enabled);
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
}

const void *studio_lua_debug_thread(StudioLua *vm) { return impl(vm)->paused; }

int studio_lua_debug_depth(StudioLua *vm) {
    lua_State *P = impl(vm)->paused;
    if (P == nullptr) {
        return 0;
    }
    lua_Debug ar;
    int depth = 0;
    while (lua_getinfo(P, depth, "l", &ar)) {
        ++depth;
    }
    return depth;
}

int studio_lua_debug_frame(StudioLua *vm, int level, const char **environment, const char **function, int *line) {
    StudioLuaImpl *self = impl(vm);
    lua_State *P = self->paused;
    lua_Debug ar;
    if (P == nullptr || !lua_getinfo(P, level, "slnf", &ar)) {
        return 0;
    }
    // "f" pushed the function: its environment says whose it is.
    self->frameEnvironment.clear();
    lua_rawcheckstack(P, 2);
    if (lua_isfunction(P, -1) && !lua_iscfunction(P, -1)) {
        lua_getfenv(P, -1);
        auto found = self->environments.find(lua_topointer(P, -1));
        if (found != self->environments.end()) {
            self->frameEnvironment = found->second;
        }
        lua_pop(P, 1);
    }
    lua_pop(P, 1);
    self->frameFunction = ar.name != nullptr ? ar.name : "";
    *environment = self->frameEnvironment.c_str();
    *function = self->frameFunction.c_str();
    *line = ar.currentline;
    return 1;
}

int studio_lua_debug_variables(StudioLua *vm, int level) {
    StudioLuaImpl *self = impl(vm);
    self->variables.clear();
    lua_State *P = self->paused;
    if (P == nullptr) {
        return 0;
    }
    lua_rawcheckstack(P, 4);
    for (int n = 1;; ++n) {
        const char *name = lua_getlocal(P, level, n);
        if (name == nullptr) {
            break;
        }
        // "(for index)" and the like are the compiler's own.
        if (name[0] != '(') {
            StudioLuaImpl::Variable variable;
            variable.name = name;
            variable.path = name;
            variable.kind = "local";
            describe(self, P, -1, variable.type, variable.value);
            // A later local of the same name hides an earlier one.
            for (auto &earlier : self->variables) {
                if (earlier.name == variable.name) {
                    earlier.name.clear();
                }
            }
            self->variables.push_back(variable);
        }
        lua_pop(P, 1);
    }
    lua_Debug ar;
    if (lua_getinfo(P, level, "f", &ar)) {
        for (int n = 1;; ++n) {
            const char *name = lua_getupvalue(P, -1, n);
            if (name == nullptr) {
                break;
            }
            if (name[0] != '\0' && name[0] != '(') {
                StudioLuaImpl::Variable variable;
                variable.name = name;
                variable.path = name;
                variable.kind = "upvalue";
                describe(self, P, -1, variable.type, variable.value);
                self->variables.push_back(variable);
            }
            lua_pop(P, 1);
        }
        lua_pop(P, 1);
    }
    std::vector<StudioLuaImpl::Variable> shown;
    for (auto &variable : self->variables) {
        if (!variable.name.empty()) {
            shown.push_back(variable);
        }
    }
    self->variables = shown;
    return static_cast<int>(self->variables.size());
}

namespace {

/// A table holding a frame's upvalues, then its locals (the later of a name winning),
/// whose metatable reads anything else from the function's environment: what a watch
/// expression sees. Pushed; false if there's no such frame.
bool pushFrameScope(lua_State *P, int level) {
    lua_Debug ar;
    lua_rawcheckstack(P, 6);
    if (!lua_getinfo(P, level, "f", &ar)) {
        return false;
    }
    int function = lua_gettop(P);
    lua_newtable(P);
    int scope = lua_gettop(P);
    for (int n = 1;; ++n) {
        const char *name = lua_getupvalue(P, function, n);
        if (name == nullptr) {
            break;
        }
        if (name[0] != '\0' && name[0] != '(') {
            lua_setfield(P, scope, name);
        } else {
            lua_pop(P, 1);
        }
    }
    for (int n = 1;; ++n) {
        const char *name = lua_getlocal(P, level, n);
        if (name == nullptr) {
            break;
        }
        if (name[0] != '(') {
            lua_setfield(P, scope, name);
        } else {
            lua_pop(P, 1);
        }
    }
    lua_newtable(P);
    lua_getfenv(P, function);
    lua_setfield(P, -2, "__index");
    lua_setmetatable(P, scope);
    lua_remove(P, function);
    return true;
}

/// Evaluates `return <expression>` in a frame's scope, leaving its value on the stack.
/// False (and the reason in the evaluation's error) if it wouldn't compile or failed.
bool evaluateInFrame(StudioLuaImpl *self, lua_State *P, int level, const char *expression) {
    self->evaluation = StudioLuaImpl::Evaluation();
    if (!pushFrameScope(P, level)) {
        self->evaluation.error = "no such frame";
        return false;
    }
    int scope = lua_gettop(P);
    std::string source = std::string("return ") + expression + "\n";
    size_t size = 0;
    lua_CompileOptions options = {};
    options.optimizationLevel = 1;
    char *bytecode = luau_compile(source.c_str(), source.size(), &options, &size);
    if (bytecode == nullptr) {
        lua_pop(P, 1);
        self->evaluation.error = "could not compile it";
        return false;
    }
    int loaded = luau_load(P, "=watch", bytecode, size, scope);
    std::free(bytecode);
    lua_remove(P, scope);
    if (loaded != 0) {
        const char *message = lua_tostring(P, -1);
        self->evaluation.error = message != nullptr ? message : "could not compile it";
        lua_pop(P, 1);
        return false;
    }
    // A moment to run, as describing a value gets.
    self->timing = true;
    self->deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(200);
    int status = lua_pcall(P, 0, 1, 0);
    self->timing = false;
    if (status != 0) {
        const char *message = lua_tostring(P, -1);
        self->evaluation.error = message != nullptr ? message : "it failed";
        lua_pop(P, 1);
        return false;
    }
    return true;
}

bool isIdentifier(const char *text, size_t length) {
    if (length == 0 || !(std::isalpha((unsigned char)text[0]) || text[0] == '_')) {
        return false;
    }
    for (size_t i = 1; i < length; ++i) {
        if (!(std::isalnum((unsigned char)text[i]) || text[i] == '_')) {
            return false;
        }
    }
    return true;
}

}  // namespace

int studio_lua_debug_evaluate(StudioLua *vm, int level, const char *expression) {
    StudioLuaImpl *self = impl(vm);
    lua_State *P = self->paused;
    if (P == nullptr) {
        self->evaluation = StudioLuaImpl::Evaluation();
        self->evaluation.error = "not paused";
        return 0;
    }
    if (!evaluateInFrame(self, P, level, expression)) {
        return 0;
    }
    self->evaluation.truthy = lua_toboolean(P, -1) != 0;
    describe(self, P, -1, self->evaluation.type, self->evaluation.value);
    lua_pop(P, 1);
    return 1;
}

void studio_lua_debug_evaluation(StudioLua *vm, const char **type, const char **value, const char **error, int *truthy) {
    StudioLuaImpl *self = impl(vm);
    *type = self->evaluation.type.c_str();
    *value = self->evaluation.value.c_str();
    *error = self->evaluation.error.c_str();
    *truthy = self->evaluation.truthy ? 1 : 0;
}

int studio_lua_debug_fields(StudioLua *vm, int level, const char *expression, int most) {
    StudioLuaImpl *self = impl(vm);
    self->variables.clear();
    lua_State *P = self->paused;
    if (P == nullptr || !evaluateInFrame(self, P, level, expression)) {
        return -1;
    }
    if (!lua_istable(P, -1)) {
        lua_pop(P, 1);
        return -1;
    }
    int table = lua_gettop(P);
    lua_rawcheckstack(P, 4);
    lua_pushnil(P);
    while (lua_next(P, table) != 0) {
        if (static_cast<int>(self->variables.size()) < most) {
            StudioLuaImpl::Variable field;
            field.kind = "field";
            if (lua_type(P, -2) == LUA_TSTRING) {
                size_t length = 0;
                const char *key = lua_tolstring(P, -2, &length);
                field.name = std::string(key, length);
                if (isIdentifier(key, length)) {
                    field.path = "." + field.name;
                } else {
                    std::string quoted;
                    for (size_t i = 0; i < length; ++i) {
                        if (key[i] == '"' || key[i] == '\\') quoted += '\\';
                        quoted += key[i];
                    }
                    field.path = "[\"" + quoted + "\"]";
                }
            } else if (lua_type(P, -2) == LUA_TNUMBER) {
                double number = lua_tonumber(P, -2);
                char text[64];
                std::snprintf(text, sizeof text, "%.14g", number);
                field.name = std::string("[") + text + "]";
                field.path = field.name;
            } else {
                std::string ignored;
                describe(self, P, -2, ignored, field.name);
                field.name = "[" + field.name + "]";
            }
            describe(self, P, -1, field.type, field.value);
            self->variables.push_back(field);
        }
        lua_pop(P, 1);
    }
    lua_pop(P, 1);
    return static_cast<int>(self->variables.size());
}

const char *studio_lua_debug_variable_path(StudioLua *vm, int index) {
    StudioLuaImpl *self = impl(vm);
    if (index < 0 || index >= static_cast<int>(self->variables.size())) {
        return "";
    }
    return self->variables[index].path.c_str();
}

void studio_lua_debug_variable(StudioLua *vm, int index, const char **name, const char **kind,
                               const char **type, const char **value) {
    StudioLuaImpl *self = impl(vm);
    if (index < 0 || index >= static_cast<int>(self->variables.size())) {
        *name = *kind = *type = *value = "";
        return;
    }
    auto &variable = self->variables[index];
    *name = variable.name.c_str();
    *kind = variable.kind.c_str();
    *type = variable.type.c_str();
    *value = variable.value.c_str();
}

}  // extern "C"
