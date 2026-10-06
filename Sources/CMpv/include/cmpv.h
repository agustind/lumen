#ifndef CMPV_H
#define CMPV_H

// libmpv is loaded at runtime (dlopen) so the app builds and launches without it.
// Every mpv entry point used by the app is exposed here as a `cmpv_*` trampoline.

#include "client.h"
#include "render.h"
#include "render_gl.h"

/// Loads libmpv from `path`. Returns 1 on success, 0 on failure (see cmpv_load_error).
int cmpv_load(const char *path);
int cmpv_is_loaded(void);
const char *cmpv_load_error(void);

unsigned long cmpv_client_api_version(void);
const char *cmpv_error_string(int error);
void cmpv_free(void *data);
void cmpv_free_node_contents(mpv_node *node);

mpv_handle *cmpv_create(void);
int cmpv_initialize(mpv_handle *ctx);
void cmpv_terminate_destroy(mpv_handle *ctx);
void cmpv_wakeup(mpv_handle *ctx);

int cmpv_set_option_string(mpv_handle *ctx, const char *name, const char *data);
int cmpv_set_property_string(mpv_handle *ctx, const char *name, const char *data);
int cmpv_set_property_double(mpv_handle *ctx, const char *name, double value);
int cmpv_set_property_flag(mpv_handle *ctx, const char *name, int value);
int cmpv_set_property_int64(mpv_handle *ctx, const char *name, int64_t value);
int cmpv_get_property_double(mpv_handle *ctx, const char *name, double *value);
int cmpv_get_property_flag(mpv_handle *ctx, const char *name, int *value);
int cmpv_get_property_node(mpv_handle *ctx, const char *name, mpv_node *node);
char *cmpv_get_property_string(mpv_handle *ctx, const char *name);

int cmpv_command(mpv_handle *ctx, const char **args);
int cmpv_command_async(mpv_handle *ctx, uint64_t reply_userdata, const char **args);
int cmpv_observe_property(mpv_handle *mpv, uint64_t reply_userdata, const char *name, mpv_format format);
int cmpv_request_log_messages(mpv_handle *ctx, const char *min_level);
mpv_event *cmpv_wait_event(mpv_handle *ctx, double timeout);
void cmpv_set_wakeup_callback(mpv_handle *ctx, void (*cb)(void *d), void *d);

/// Creates an OpenGL render context. The caller's CGL context must be current.
int cmpv_render_context_create_gl(mpv_render_context **res, mpv_handle *mpv);
void cmpv_render_context_set_update_callback(mpv_render_context *ctx, mpv_render_update_fn callback, void *callback_ctx);
uint64_t cmpv_render_context_update(mpv_render_context *ctx);
/// Renders into framebuffer `fbo` sized `w`x`h` (flipped for CAOpenGLLayer).
int cmpv_render_context_render_gl(mpv_render_context *ctx, int fbo, int w, int h);
void cmpv_render_context_report_swap(mpv_render_context *ctx);
void cmpv_render_context_free(mpv_render_context *ctx);

#endif
