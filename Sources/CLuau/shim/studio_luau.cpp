#include "studio_luau.h"

#include "lua.h"
#include "lualib.h"
#include "luacode.h"

#include <chrono>
#include <cstring>
#include <string>

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
    int results = self->invoke(self->context, opaque(self), lua_gettop(L));
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

    // Fall through to the real globals for anything the script did not define.
    lua_newtable(L);
    lua_pushvalue(L, LUA_GLOBALSINDEX);
    lua_setfield(L, -2, "__index");
    lua_setmetatable(L, -2);

    lua_setfield(L, LUA_REGISTRYINDEX, environmentKey(name).c_str());
}

void studio_lua_drop_environment(StudioLua *vm, const char *name) {
    lua_State *L = impl(vm)->state;
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
    options.debugLevel = 1;
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
