// Minimal C ABI over llama.cpp so Swift never has to import ggml's structs.
//
// Deliberately passes only scalars and pointers: Swift's `@convention(c)`
// rejects by-value Swift structs as "not representable in Objective-C", so a
// struct-based ABI would force a bridging header just to import the types.
#ifndef JX_LLAMA_BRIDGE_H
#define JX_LLAMA_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct JXLLamaModel JXLLamaModel;

/// Call once at startup. Returns 0 on success.
int  jxllm_init(void);
void jxllm_shutdown(void);

/// Sensible thread count for this machine.
int32_t jxllm_default_threads(void);

/// Load a GGUF. `n_gpu_layers` < 0 means all layers on the GPU.
/// `on_progress` may be NULL; it receives 0.0…1.0.
JXLLamaModel *jxllm_load(const char *path,
                         int32_t n_ctx,
                         int32_t n_batch,
                         int32_t n_ubatch,
                         int32_t n_gpu_layers,
                         int32_t n_threads,
                         int32_t flash_attn,
                         void (*on_progress)(float progress, void *user),
                         void *user);
void jxllm_release(JXLLamaModel *m);

int32_t jxllm_n_ctx(JXLLamaModel *m);
int32_t jxllm_n_ctx_train(JXLLamaModel *m);
int32_t jxllm_n_vocab(JXLLamaModel *m);
void    jxllm_clear_kv(JXLLamaModel *m);
void    jxllm_cancel(JXLLamaModel *m);

/// Apply the model's built-in chat template. `roles`/`msgs` are parallel
/// arrays of `n_msg`. Returns a malloc'd UTF-8 string, or NULL.
char *jxllm_apply_chat_template(JXLLamaModel *m,
                                const char **roles,
                                const char **msgs,
                                int32_t n_msg,
                                int32_t add_assistant);

/// Tokenise text. Returns the token count, or negative on failure.
/// A NULL `tokens` makes this a sizing query.
int32_t jxllm_tokenize(JXLLamaModel *m, const char *text,
                       int32_t *tokens, int32_t capacity, int32_t add_special);

/// Run a completion. `on_token` receives NUL-terminated UTF-8 pieces.
/// Returns 0 on success, 1 if cancelled, negative on error.
int jxllm_generate(JXLLamaModel *m,
                   const char *prompt,
                   float    temperature,
                   float    top_p,
                   int32_t  top_k,
                   float    repeat_penalty,
                   int32_t  max_tokens,
                   uint32_t seed,
                   void (*on_token)(const char *piece, void *user),
                   void *user,
                   int32_t *out_tokens);

/// Last error message, or NULL. Valid until the next call in this module.
const char *jxllm_last_error(void);

#ifdef __cplusplus
}
#endif
#endif
