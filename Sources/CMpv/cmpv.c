#include "cmpv.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

static void *lib_handle = NULL;
static char load_error[1024] = {0};

#define CMPV_SYMBOLS(X)                  \
    X(mpv_client_api_version)            \
    X(mpv_error_string)                  \
    X(mpv_free)                          \
    X(mpv_free_node_contents)            \
    X(mpv_create)                        \
    X(mpv_initialize)                    \
    X(mpv_terminate_destroy)             \
    X(mpv_wakeup)                        \
    X(mpv_set_option_string)             \
    X(mpv_set_property)                  \
    X(mpv_set_property_string)           \
    X(mpv_get_property)                  \
    X(mpv_get_property_string)           \
    X(mpv_command)                       \
    X(mpv_command_async)                 \
    X(mpv_observe_property)              \
    X(mpv_request_log_messages)          \
    X(mpv_wait_event)                    \
    X(mpv_set_wakeup_callback)           \
    X(mpv_render_context_create)         \
    X(mpv_render_context_set_update_callback) \
    X(mpv_render_context_update)         \
    X(mpv_render_context_render)         \
    X(mpv_render_context_report_swap)    \
    X(mpv_render_context_free)

#define CMPV_DECLARE(name) static __typeof__(&name) p_##name = NULL;
CMPV_SYMBOLS(CMPV_DECLARE)

int cmpv_load(const char *path) {
    if (lib_handle) return 1;
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *err = dlerror();
        snprintf(load_error, sizeof(load_error), "%s", err ? err : "dlopen failed");
        return 0;
    }
#define CMPV_RESOLVE(name)                                                     \
    p_##name = (__typeof__(&name))dlsym(handle, #name);                       \
    if (!p_##name) {                                                           \
        snprintf(load_error, sizeof(load_error), "missing symbol " #name);    \
        dlclose(handle);                                                       \
        return 0;                                                              \
    }
    CMPV_SYMBOLS(CMPV_RESOLVE)
#undef CMPV_RESOLVE
    if ((p_mpv_client_api_version() >> 16) != 2) {
        snprintf(load_error, sizeof(load_error), "unsupported libmpv client API %lu",
                 p_mpv_client_api_version() >> 16);
        dlclose(handle);
        return 0;
    }
    lib_handle = handle;
    load_error[0] = 0;
    return 1;
}

int cmpv_is_loaded(void) { return lib_handle != NULL; }
const char *cmpv_load_error(void) { return load_error; }

unsigned long cmpv_client_api_version(void) { return p_mpv_client_api_version(); }
const char *cmpv_error_string(int error) { return p_mpv_error_string(error); }
void cmpv_free(void *data) { p_mpv_free(data); }
void cmpv_free_node_contents(mpv_node *node) { p_mpv_free_node_contents(node); }

mpv_handle *cmpv_create(void) { return p_mpv_create(); }
int cmpv_initialize(mpv_handle *ctx) { return p_mpv_initialize(ctx); }
void cmpv_terminate_destroy(mpv_handle *ctx) { p_mpv_terminate_destroy(ctx); }
void cmpv_wakeup(mpv_handle *ctx) { p_mpv_wakeup(ctx); }

int cmpv_set_option_string(mpv_handle *ctx, const char *name, const char *data) {
    return p_mpv_set_option_string(ctx, name, data);
}
int cmpv_set_property_string(mpv_handle *ctx, const char *name, const char *data) {
    return p_mpv_set_property_string(ctx, name, data);
}
int cmpv_set_property_double(mpv_handle *ctx, const char *name, double value) {
    return p_mpv_set_property(ctx, name, MPV_FORMAT_DOUBLE, &value);
}
int cmpv_set_property_flag(mpv_handle *ctx, const char *name, int value) {
    return p_mpv_set_property(ctx, name, MPV_FORMAT_FLAG, &value);
}
int cmpv_set_property_int64(mpv_handle *ctx, const char *name, int64_t value) {
    return p_mpv_set_property(ctx, name, MPV_FORMAT_INT64, &value);
}
int cmpv_get_property_double(mpv_handle *ctx, const char *name, double *value) {
    return p_mpv_get_property(ctx, name, MPV_FORMAT_DOUBLE, value);
}
int cmpv_get_property_flag(mpv_handle *ctx, const char *name, int *value) {
    return p_mpv_get_property(ctx, name, MPV_FORMAT_FLAG, value);
}
int cmpv_get_property_node(mpv_handle *ctx, const char *name, mpv_node *node) {
    return p_mpv_get_property(ctx, name, MPV_FORMAT_NODE, node);
}
char *cmpv_get_property_string(mpv_handle *ctx, const char *name) {
    return p_mpv_get_property_string(ctx, name);
}

int cmpv_command(mpv_handle *ctx, const char **args) { return p_mpv_command(ctx, args); }
int cmpv_command_async(mpv_handle *ctx, uint64_t reply_userdata, const char **args) {
    return p_mpv_command_async(ctx, reply_userdata, args);
}
int cmpv_observe_property(mpv_handle *mpv, uint64_t reply_userdata, const char *name, mpv_format format) {
    return p_mpv_observe_property(mpv, reply_userdata, name, format);
}
int cmpv_request_log_messages(mpv_handle *ctx, const char *min_level) {
    return p_mpv_request_log_messages(ctx, min_level);
}
mpv_event *cmpv_wait_event(mpv_handle *ctx, double timeout) { return p_mpv_wait_event(ctx, timeout); }
void cmpv_set_wakeup_callback(mpv_handle *ctx, void (*cb)(void *d), void *d) {
    p_mpv_set_wakeup_callback(ctx, cb, d);
}

static void *gl_get_proc_address(void *ctx, const char *name) {
    (void)ctx;
    static void *opengl = NULL;
    if (!opengl) opengl = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY | RTLD_LOCAL);
    return opengl ? dlsym(opengl, name) : NULL;
}

int cmpv_render_context_create_gl(mpv_render_context **res, mpv_handle *mpv) {
    mpv_opengl_init_params gl_init = {
        .get_proc_address = gl_get_proc_address,
        .get_proc_address_ctx = NULL,
    };
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init},
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    return p_mpv_render_context_create(res, mpv, params);
}

void cmpv_render_context_set_update_callback(mpv_render_context *ctx, mpv_render_update_fn callback, void *callback_ctx) {
    p_mpv_render_context_set_update_callback(ctx, callback, callback_ctx);
}
uint64_t cmpv_render_context_update(mpv_render_context *ctx) { return p_mpv_render_context_update(ctx); }

int cmpv_render_context_render_gl(mpv_render_context *ctx, int fbo, int w, int h) {
    mpv_opengl_fbo target = {.fbo = fbo, .w = w, .h = h, .internal_format = 0};
    int flip_y = 1;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_OPENGL_FBO, &target},
        {MPV_RENDER_PARAM_FLIP_Y, &flip_y},
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    return p_mpv_render_context_render(ctx, params);
}
void cmpv_render_context_report_swap(mpv_render_context *ctx) { p_mpv_render_context_report_swap(ctx); }
void cmpv_render_context_free(mpv_render_context *ctx) { p_mpv_render_context_free(ctx); }
