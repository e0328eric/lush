/* Isolated Lua state and raw-data boundary for untrusted theme files. */
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <time.h>
#endif

#define THEME_MEMORY_LIMIT ((size_t)8 * 1024 * 1024)
#define THEME_SOURCE_LIMIT ((size_t)256 * 1024)
#define THEME_COPY_BYTES ((size_t)256 * 1024)
#define THEME_COPY_NODES 4096
#define THEME_COPY_DEPTH 32
#define THEME_INSTRUCTIONS 500000
#define THEME_WALL_MS 250
#define THEME_HANDLE_META "lush.theme.vm"

typedef struct ThemeVM {
    lua_State *state;
    size_t used;
    int remaining;
    int exhausted;
    int builder_ref;
    uint64_t deadline;
} ThemeVM;

typedef struct ThemeHandle {
    ThemeVM *vm;
    char failure[1024];
} ThemeHandle;

typedef struct CopyLimit {
    int nodes;
    size_t bytes;
    const void *ancestors[THEME_COPY_DEPTH];
    const char *error;
} CopyLimit;

typedef struct Initialization {
    ThemeVM *vm;
    const char *theme;
    size_t theme_length;
    const char *runner;
    size_t runner_length;
    const char *source;
    size_t source_length;
    const char *filename;
} Initialization;

typedef struct BuilderCall {
    ThemeVM *vm;
    lua_State *host;
} BuilderCall;

static uint64_t monotonic_ms(void) {
#if defined(_WIN32)
    return (uint64_t)GetTickCount64();
#else
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
#endif
}

static void *theme_allocate(void *opaque, void *pointer, size_t old_size, size_t new_size) {
    ThemeVM *vm = (ThemeVM *)opaque;
    void *result;
    if (!pointer) old_size = 0; /* Lua supplies a type tag for fresh allocations. */
    if (new_size == 0) {
        free(pointer);
        vm->used -= old_size;
        return NULL;
    }
    if (new_size > THEME_MEMORY_LIMIT || vm->used - old_size > THEME_MEMORY_LIMIT - new_size) return NULL;
    result = realloc(pointer, new_size);
    if (result) vm->used = vm->used - old_size + new_size;
    return result;
}

static void theme_hook(lua_State *state, lua_Debug *record) {
    ThemeVM *vm = *(ThemeVM **)lua_getextraspace(state);
    (void)record;
    vm->remaining -= 1000;
    if (vm->exhausted || vm->remaining <= 0 || monotonic_ms() >= vm->deadline) {
        vm->exhausted = 1;
        /* A trusted helper might catch an error internally. Keep the failure
           sticky and stop it again on the very next Lua instruction. */
        lua_sethook(state, theme_hook, LUA_MASKCOUNT, 1);
        luaL_error(state, "theme execution budget exceeded");
    }
}

static void start_budget(ThemeVM *vm) {
    vm->remaining = THEME_INSTRUCTIONS;
    vm->exhausted = 0;
    vm->deadline = monotonic_ms() + THEME_WALL_MS;
    lua_sethook(vm->state, theme_hook, LUA_MASKCOUNT, 1000);
}

static void close_vm(ThemeHandle *handle) {
    ThemeVM *vm = handle->vm;
    if (!vm) return;
    handle->vm = NULL;
    if (vm->state) {
        lua_sethook(vm->state, NULL, 0, 0);
        lua_close(vm->state);
    }
    free(vm);
}

static int collect_handle(lua_State *host) {
    ThemeHandle *handle = (ThemeHandle *)luaL_testudata(host, 1, THEME_HANDLE_META);
    if (handle) close_vm(handle);
    return 0;
}

static void handle_metatable(lua_State *host) {
    if (luaL_newmetatable(host, THEME_HANDLE_META)) {
        lua_pushcfunction(host, collect_handle);
        lua_setfield(host, -2, "__gc");
        lua_pushliteral(host, "protected theme sandbox");
        lua_setfield(host, -2, "__metatable");
    }
}

static int copy_fail(CopyLimit *limit, const char *message) {
    limit->error = message;
    return 0;
}

/* This never invokes a Lua callback or metamethod on either state. When the
   destination is the quota-limited VM, the caller runs it inside lua_pcall. */
static int copy_value(lua_State *from, int index, lua_State *to, CopyLimit *limit, int depth) {
    int kind;
    index = lua_absindex(from, index);
    if (++limit->nodes > THEME_COPY_NODES) return copy_fail(limit, "data exceeds the 4096-node transfer limit");
    if (!lua_checkstack(from, 6) || !lua_checkstack(to, 6)) return copy_fail(limit, "cannot grow the data transfer stack");
    kind = lua_type(from, index);
    switch (kind) {
    case LUA_TNIL: lua_pushnil(to); return 1;
    case LUA_TBOOLEAN: lua_pushboolean(to, lua_toboolean(from, index)); return 1;
    case LUA_TNUMBER:
        if (lua_isinteger(from, index)) lua_pushinteger(to, lua_tointeger(from, index));
        else {
            lua_Number value = lua_tonumber(from, index);
            if (!isfinite(value)) return copy_fail(limit, "data must contain finite numbers");
            lua_pushnumber(to, value);
        }
        return 1;
    case LUA_TSTRING: {
        size_t length;
        const char *text = lua_tolstring(from, index, &length);
        if (length > THEME_COPY_BYTES - limit->bytes) return copy_fail(limit, "data exceeds the 256 KiB transfer limit");
        limit->bytes += length;
        lua_pushlstring(to, text, length);
        return 1;
    }
    case LUA_TTABLE: {
        const void *identity;
        int at;
        if (depth >= THEME_COPY_DEPTH) return copy_fail(limit, "data exceeds the 32-level transfer depth");
        if (lua_getmetatable(from, index)) {
            lua_pop(from, 1);
            return copy_fail(limit, "data tables must not have metatables");
        }
        identity = lua_topointer(from, index);
        for (at = 0; at < depth; ++at)
            if (limit->ancestors[at] == identity) return copy_fail(limit, "cyclic data tables are not allowed");
        limit->ancestors[depth] = identity;
        lua_newtable(to);
        lua_pushnil(from);
        while (lua_next(from, index)) {
            int key_kind = lua_type(from, -2);
            if (key_kind != LUA_TSTRING && key_kind != LUA_TNUMBER && key_kind != LUA_TBOOLEAN) {
                lua_pop(from, 2);
                return copy_fail(limit, "data keys must be strings, numbers, or booleans");
            }
            if (!copy_value(from, -2, to, limit, depth + 1) || !copy_value(from, -1, to, limit, depth + 1)) {
                lua_pop(from, 2);
                return 0;
            }
            lua_rawset(to, -3);
            lua_pop(from, 1);
        }
        return 1;
    }
    default: return copy_fail(limit, "data must not contain functions, threads, or userdata");
    }
}

/* Errors are untrusted strings as well: keep terminal controls out of host
   diagnostics and bound their storage without tostring/metatable callbacks. */
static void error_text(char *output, size_t capacity, ThemeVM *vm, int status, const char *fallback) {
    size_t at = 0, length = 0, index;
    const char *message = fallback;
    if (vm->exhausted) message = "execution budget exceeded";
    else if (status == LUA_ERRMEM) message = "memory limit exceeded (8 MiB)";
    else if (lua_type(vm->state, -1) == LUA_TSTRING) message = lua_tolstring(vm->state, -1, &length);
    if (!length) length = strlen(message);
    at = (size_t)snprintf(output, capacity, "theme sandbox: ");
    if (at >= capacity) at = capacity - 1;
    for (index = 0; index < length && at + 1 < capacity; ++index) {
        unsigned char byte = (unsigned char)message[index];
        if (byte < 32 || byte == 127 || byte >= 128) {
            if (at + 4 >= capacity) break;
            snprintf(output + at, capacity - at, "\\x%02x", byte);
            at += 4;
        } else output[at++] = (char)byte;
    }
    output[at] = '\0';
}

static int initialize_vm(lua_State *state) {
    Initialization *initial = (Initialization *)lua_touserdata(state, 1);
    int status;
    luaL_requiref(state, LUA_GNAME, luaopen_base, 1); lua_pop(state, 1);
    luaL_requiref(state, LUA_TABLIBNAME, luaopen_table, 1); lua_pop(state, 1);
    luaL_requiref(state, LUA_STRLIBNAME, luaopen_string, 1); lua_pop(state, 1);
    luaL_requiref(state, LUA_MATHLIBNAME, luaopen_math, 1); lua_pop(state, 1);
    luaL_requiref(state, LUA_UTF8LIBNAME, luaopen_utf8, 1); lua_pop(state, 1);
    lua_newtable(state);
    lua_newtable(state); lua_setfield(state, -2, "config");
    lua_newtable(state); lua_setfield(state, -2, "null");
    lua_setglobal(state, "lush");
    lua_newtable(state); lua_setglobal(state, "_lush");
    status = luaL_loadbufferx(state, initial->theme, initial->theme_length, "@lush/theme.lua", "t");
    if (status != LUA_OK) return lua_error(state);
    lua_call(state, 0, 0);
    status = luaL_loadbufferx(state, initial->runner, initial->runner_length, "@lush/theme_sandbox.lua", "t");
    if (status != LUA_OK) return lua_error(state);
    lua_call(state, 0, 1);
    if (!lua_isfunction(state, -1)) return luaL_error(state, "trusted theme runner did not return a compiler");
    lua_pushlstring(state, initial->source, initial->source_length);
    lua_pushstring(state, initial->filename);
    lua_call(state, 2, 1);
    if (lua_isfunction(state, -1)) {
        initial->vm->builder_ref = luaL_ref(state, LUA_REGISTRYINDEX);
        return 0;
    }
    return 1;
}

static int invoke_builder(lua_State *state) {
    BuilderCall *call = (BuilderCall *)lua_touserdata(state, 1);
    CopyLimit limit;
    memset(&limit, 0, sizeof(limit));
    lua_rawgeti(state, LUA_REGISTRYINDEX, call->vm->builder_ref);
    if (!copy_value(call->host, 1, state, &limit, 0) || !copy_value(call->host, 2, state, &limit, 0))
        return luaL_error(state, "%s", limit.error);
    lua_call(state, 2, 1);
    return 1;
}

static int host_builder(lua_State *host) {
    ThemeHandle *handle = (ThemeHandle *)luaL_testudata(host, lua_upvalueindex(1), THEME_HANDLE_META);
    ThemeVM *vm;
    BuilderCall call;
    CopyLimit limit;
    int status, host_top = lua_gettop(host);
    if (!handle || !handle->vm) {
        lua_pushstring(host, handle && handle->failure[0] ? handle->failure : "theme sandbox is closed");
        return lua_error(host);
    }
    /* Missing optional arguments copy as nil; ensure both source slots exist. */
    if (host_top < 2) lua_settop(host, 2);
    host_top = lua_gettop(host);
    vm = handle->vm;
    lua_settop(vm->state, 0);
    call.vm = vm; call.host = host;
    lua_pushcfunction(vm->state, invoke_builder);
    lua_pushlightuserdata(vm->state, &call);
    start_budget(vm);
    status = lua_pcall(vm->state, 1, 1, 0);
    lua_sethook(vm->state, NULL, 0, 0);
    if (status != LUA_OK || vm->exhausted) {
        error_text(handle->failure, sizeof(handle->failure), vm, status, "builder failed");
        close_vm(handle);
        lua_pushstring(host, handle->failure);
        return lua_error(host);
    }
    memset(&limit, 0, sizeof(limit));
    if (!copy_value(vm->state, -1, host, &limit, 0)) {
        snprintf(handle->failure, sizeof(handle->failure), "theme sandbox: %s", limit.error);
        lua_settop(host, host_top);
        close_vm(handle);
        lua_pushstring(host, handle->failure);
        return lua_error(host);
    }
    lua_settop(vm->state, 0);
    return 1;
}

/* Host arguments 1/2 are source bytes and a filename. Trusted utility/runner
   source belongs to the executable, not the selected file or host globals. */
int lush_theme_compile(lua_State *host, const char *theme_source, size_t theme_length,
                       const char *runner_source, size_t runner_length) {
    size_t source_length, filename_length;
    const char *source, *filename;
    ThemeHandle *handle;
    ThemeVM *vm;
    Initialization initial;
    CopyLimit limit;
    int status, handle_index;
    if (lua_type(host, 1) != LUA_TSTRING || lua_type(host, 2) != LUA_TSTRING) {
        lua_pushnil(host); lua_pushliteral(host, "theme sandbox: expected source and filename strings"); return 2;
    }
    source = lua_tolstring(host, 1, &source_length);
    filename = lua_tolstring(host, 2, &filename_length);
    if (source_length > THEME_SOURCE_LIMIT || filename_length > 4096 || memchr(filename, '\0', filename_length)) {
        lua_pushnil(host); lua_pushliteral(host, "theme sandbox: source exceeds 256 KiB or filename is invalid"); return 2;
    }
    handle = (ThemeHandle *)lua_newuserdatauv(host, sizeof(*handle), 0);
    memset(handle, 0, sizeof(*handle));
    handle_index = lua_gettop(host);
    handle_metatable(host); lua_setmetatable(host, handle_index);
    vm = (ThemeVM *)calloc(1, sizeof(*vm));
    if (!vm) {
        lua_pushnil(host); lua_pushliteral(host, "theme sandbox: cannot allocate isolated state"); return 2;
    }
    handle->vm = vm;
    vm->builder_ref = LUA_NOREF;
    vm->state = lua_newstate(theme_allocate, vm, luaL_makeseed(NULL));
    if (!vm->state) {
        close_vm(handle); lua_pushnil(host); lua_pushliteral(host, "theme sandbox: cannot allocate isolated state"); return 2;
    }
    *(ThemeVM **)lua_getextraspace(vm->state) = vm;
    initial.vm = vm;
    initial.theme = theme_source; initial.theme_length = theme_length;
    initial.runner = runner_source; initial.runner_length = runner_length;
    initial.source = source; initial.source_length = source_length; initial.filename = filename;
    lua_pushcfunction(vm->state, initialize_vm);
    lua_pushlightuserdata(vm->state, &initial);
    start_budget(vm);
    status = lua_pcall(vm->state, 1, LUA_MULTRET, 0);
    lua_sethook(vm->state, NULL, 0, 0);
    if (status != LUA_OK || vm->exhausted) {
        error_text(handle->failure, sizeof(handle->failure), vm, status, "theme initialization failed");
        close_vm(handle);
        lua_pushnil(host); lua_pushstring(host, handle->failure); return 2;
    }
    if (vm->builder_ref != LUA_NOREF) {
        lua_pushvalue(host, handle_index);
        lua_pushcclosure(host, host_builder, 1);
        return 1;
    }
    memset(&limit, 0, sizeof(limit));
    if (!copy_value(vm->state, -1, host, &limit, 0)) {
        close_vm(handle); lua_settop(host, handle_index);
        lua_pushnil(host); lua_pushfstring(host, "theme sandbox: %s", limit.error); return 2;
    }
    close_vm(handle);
    return 1;
}
