// C++ implementation of the jxllm C ABI. Kept intentionally small: Swift
// talks to these ~15 functions instead of to ggml directly.
#include "jx_llama_bridge.h"

#include "llama.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

// The opaque handle. Defined at global scope so the header's typedef and this
// definition describe one and the same type.
struct JXLLamaModel {
    llama_model      *model = nullptr;
    llama_context    *ctx   = nullptr;
    std::atomic<bool> cancelled{false};
};

namespace {

std::string g_last_error;

void set_error(const std::string &s) { g_last_error = s; }

struct ProgressCtx {
    void (*fn)(float, void *) = nullptr;
    void *user = nullptr;
};

// llama_progress_callback returns bool: false aborts the load.
bool progress_cb(float progress, void *user) {
    auto *pc = static_cast<ProgressCtx *>(user);
    if (pc && pc->fn) pc->fn(progress, pc->user);
    return true;
}

} // namespace

extern "C" {

int32_t jxllm_default_threads(void) {
    unsigned hc = std::thread::hardware_concurrency();
    if (hc == 0) hc = 4;
    return (int32_t)(hc > 8 ? hc - 2 : hc);
}

int jxllm_init(void) {
    llama_backend_init();
    return 0;
}

void jxllm_shutdown(void) { llama_backend_free(); }

JXLLamaModel *jxllm_load(const char *path,
                         int32_t n_ctx,
                         int32_t n_batch,
                         int32_t n_ubatch,
                         int32_t n_gpu_layers,
                         int32_t n_threads,
                         int32_t flash_attn,
                         void (*on_progress)(float, void *), void *user) {
    if (!path || !*path) { set_error("empty model path"); return nullptr; }

llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = n_gpu_layers;

    ProgressCtx pc{on_progress, user};
    if (on_progress) {
        mp.progress_callback = progress_cb;
        mp.progress_callback_user_data = &pc;
    }

    llama_model *model = llama_model_load_from_file(path, mp);
    if (!model) { set_error(std::string("failed to load model: ") + path); return nullptr; }

    llama_context_params cp = llama_context_default_params();
    if (n_ctx > 0) cp.n_ctx = (uint32_t)n_ctx;
    if (n_batch > 0) cp.n_batch = (uint32_t)n_batch;
    if (n_ubatch > 0) cp.n_ubatch = (uint32_t)n_ubatch;
    if (n_threads <= 0) n_threads = jxllm_default_threads();
    cp.n_threads = n_threads;
    cp.n_threads_batch = n_threads;
    if (flash_attn == 1) cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
    else if (flash_attn == 2) cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED;

    llama_context *ctx = llama_init_from_model(model, cp);
    if (!ctx) {
        llama_model_free(model);
        set_error("failed to create context (out of memory?)");
        return nullptr;
    }

    auto *m = new JXLLamaModel();
    m->model = model;
    m->ctx = ctx;
    return m;
}

void jxllm_release(JXLLamaModel *m) {
    if (!m) return;
    if (m->ctx) llama_free(m->ctx);
    if (m->model) llama_model_free(m->model);
    delete m;
}

int32_t jxllm_n_ctx(JXLLamaModel *m) { return m ? (int32_t)llama_n_ctx(m->ctx) : 0; }
int32_t jxllm_n_ctx_train(JXLLamaModel *m) { return m ? llama_model_n_ctx_train(m->model) : 0; }

int32_t jxllm_n_vocab(JXLLamaModel *m) {
    if (!m) return 0;
    const llama_vocab *v = llama_model_get_vocab(m->model);
    return v ? llama_vocab_n_tokens(v) : 0;
}

void jxllm_clear_kv(JXLLamaModel *m) {
    if (!m || !m->ctx) return;
    llama_memory_t mem = llama_get_memory(m->ctx);
    if (mem) llama_memory_clear(mem, true);
}

void jxllm_cancel(JXLLamaModel *m) { if (m) m->cancelled.store(true); }

char *jxllm_apply_chat_template(JXLLamaModel *m,
                                const char **roles,
                                const char **msgs,
                                int32_t n_msg,
                                int32_t add_assistant) {
    if (!m || n_msg <= 0) return nullptr;

    const char *tmpl = llama_model_chat_template(m->model, nullptr);

    std::vector<llama_chat_message> chat;
    chat.reserve(n_msg);
    for (int32_t i = 0; i < n_msg; i++) {
        chat.push_back(llama_chat_message{roles ? roles[i] : "user", msgs[i]});
    }

    // First call sizes the buffer; second fills it.
    int32_t len = llama_chat_apply_template(tmpl, chat.data(), chat.size(),
                                            add_assistant != 0, nullptr, 0);
    if (len < 0) { set_error("chat template failed"); return nullptr; }

    std::vector<char> buf((size_t)len + 1, 0);
    int32_t written = llama_chat_apply_template(tmpl, chat.data(), chat.size(),
                                                add_assistant != 0, buf.data(), (int32_t)buf.size());
    if (written < 0) { set_error("chat template failed"); return nullptr; }
    buf[(size_t)written] = 0;

    char *out = (char *)malloc((size_t)written + 1);
    if (!out) return nullptr;
    memcpy(out, buf.data(), (size_t)written + 1);
    return out;
}

int32_t jxllm_tokenize(JXLLamaModel *m, const char *text,
                       int32_t *tokens, int32_t capacity, int32_t add_special) {
    if (!m || !text) return -1;
    const llama_vocab *vocab = llama_model_get_vocab(m->model);
    if (!vocab) return -1;
    int32_t n = llama_tokenize(vocab, text, (int32_t)strlen(text),
                               tokens ? tokens : nullptr,
                               tokens ? capacity : 0,
                               add_special != 0, true);
    return n;
}

int jxllm_generate(JXLLamaModel *m,
                   const char *prompt,
                   float    temperature,
                   float    top_p,
                   int32_t  top_k,
                   float    repeat_penalty,
                   int32_t  max_tokens,
                   uint32_t seed,
                   void (*on_token)(const char *, void *),
                   void *user,
                   int32_t *out_tokens) {
    if (!m || !m->ctx || !prompt) { set_error("no context"); return -1; }
    if (out_tokens) *out_tokens = 0;

    m->cancelled.store(false);

    const llama_vocab *vocab = llama_model_get_vocab(m->model);
    const int32_t n_ctx = (int32_t)llama_n_ctx(m->ctx);

    // Tokenise (prompt length + 1 for the vocab query)
    int32_t n_prompt = -llama_tokenize(vocab, prompt, (int32_t)strlen(prompt),
                                       nullptr, 0, true, true);
    if (n_prompt <= 0) { set_error("tokenize failed"); return -2; }

    std::vector<llama_token> prompt_tokens((size_t)n_prompt);
    int32_t got = llama_tokenize(vocab, prompt, (int32_t)strlen(prompt),
                                 prompt_tokens.data(), n_prompt, true, true);
    if (got <= 0) { set_error("tokenize failed"); return -2; }
    prompt_tokens.resize((size_t)got);

    if (got > n_ctx - 4) { set_error("prompt exceeds context"); return -3; }

    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    llama_sampler *smpl = llama_sampler_chain_init(sparams);
    const int32_t n_vocab = llama_vocab_n_tokens(vocab);
    if (repeat_penalty > 1.0f) {
        llama_sampler_chain_add(smpl, llama_sampler_init_penalties(
            n_vocab, 64, repeat_penalty, 0.0f, 0.0f));
    }
    if (top_k > 0) llama_sampler_chain_add(smpl, llama_sampler_init_top_k(top_k));
    if (top_p > 0.0f && top_p < 1.0f) llama_sampler_chain_add(smpl, llama_sampler_init_top_p(top_p, 1));
    if (temperature > 0.0f) llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(seed ? seed : LLAMA_DEFAULT_SEED));

    const int32_t n_batch = (int32_t)std::max(1, (int)llama_n_ctx(m->ctx) > 0 ? 512 : 512);

    // --- prompt eval, chunked to n_batch ---
    int32_t n_past = 0;
    while (n_past < (int32_t)prompt_tokens.size()) {
        int32_t chunk = std::min(n_batch, (int32_t)prompt_tokens.size() - n_past);
        llama_batch batch = llama_batch_get_one(prompt_tokens.data() + n_past, chunk);
        if (llama_decode(m->ctx, batch) != 0) {
            llama_sampler_free(smpl);
            set_error("prompt decode failed");
            return -4;
        }
        n_past += chunk;
        if (m->cancelled.load()) { llama_sampler_free(smpl); return 1; }
    }

    // --- generation ---
    int32_t n_decoded = 0;
    const llama_token eos = llama_vocab_eos(vocab);
    llama_token last = llama_sampler_sample(smpl, m->ctx, -1);

    std::vector<char> piece(256, 0);

    while (true) {
        if (last == eos || llama_vocab_is_eog(vocab, last)) break;
        if (max_tokens > 0 && n_decoded >= max_tokens) break;
        if (m->cancelled.load()) { llama_sampler_free(smpl); return 1; }

        int32_t n = llama_token_to_piece(vocab, last, piece.data(), (int32_t)piece.size(), 0, true);
        if (n < 0) {
            // buffer too small for a multi-byte piece; grow and retry once
            piece.resize(1024, 0);
            n = llama_token_to_piece(vocab, last, piece.data(), (int32_t)piece.size(), 0, true);
        }
        if (n > 0) {
            std::string out(piece.data(), (size_t)n);
            if (on_token) on_token(out.c_str(), user);
        }

        llama_batch batch = llama_batch_get_one(&last, 1);
        if (llama_decode(m->ctx, batch) != 0) {
            llama_sampler_free(smpl);
            set_error("decode failed");
            return -5;
        }
        n_decoded++;
        last = llama_sampler_sample(smpl, m->ctx, -1);
    }

    llama_sampler_free(smpl);
    if (out_tokens) *out_tokens = n_decoded;
    return 0;
}

const char *jxllm_last_error(void) {
    return g_last_error.empty() ? nullptr : g_last_error.c_str();
}

} // extern "C"
