#include "adblock_engine.h"
#include <mutex>
#include <memory>
#include <vector>
#include <string_view>
#include <cctype>

struct AdBlockEngineWrapper {
    std::mutex mutex;
    std::shared_ptr<AdBlockEngineImpl> impl;
};

extern "C" {

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

EXPORT void* aurora_adblock_create() {
    auto* wrapper = new AdBlockEngineWrapper();
    wrapper->impl = std::make_shared<AdBlockEngineImpl>();
    return static_cast<void*>(wrapper);
}

EXPORT void aurora_adblock_load_rules(void* engine, const char* rulesUtf8) {
    if (!engine || !rulesUtf8) return;
    auto* wrapper = static_cast<AdBlockEngineWrapper*>(engine);
    
    auto new_impl = std::make_shared<AdBlockEngineImpl>();
    new_impl->load_rules(std::string(rulesUtf8));
    
    std::lock_guard<std::mutex> lock(wrapper->mutex);
    wrapper->impl = new_impl;
}

EXPORT int aurora_adblock_should_block(void* engine, const char* urlUtf8) {
    if (!engine || !urlUtf8) return 0;
    auto* wrapper = static_cast<AdBlockEngineWrapper*>(engine);
    
    std::shared_ptr<AdBlockEngineImpl> current_impl;
    {
        std::lock_guard<std::mutex> lock(wrapper->mutex);
        current_impl = wrapper->impl;
    }
    
    if (current_impl) {
        // string_view: no heap copy for the per-request URL.
        return current_impl->should_block_ex(std::string_view(urlUtf8), "", "", false) ? 1 : 0;
    }
    return 0;
}

EXPORT int aurora_adblock_should_block_ex(
    void* engine, 
    const char* urlUtf8, 
    const char* sourceHostUtf8, 
    const char* requestTypeUtf8, 
    int isThirdParty
) {
    if (!engine || !urlUtf8) return 0;
    auto* wrapper = static_cast<AdBlockEngineWrapper*>(engine);
    
    std::shared_ptr<AdBlockEngineImpl> current_impl;
    {
        std::lock_guard<std::mutex> lock(wrapper->mutex);
        current_impl = wrapper->impl;
    }
    
    if (current_impl) {
        // string_view: zero-copy views over the Dart-provided buffers -- no
        // per-request std::string heap allocations at the FFI boundary.
        std::string_view url(urlUtf8);
        std::string_view source_host(sourceHostUtf8 ? sourceHostUtf8 : "");
        std::string_view request_type(requestTypeUtf8 ? requestTypeUtf8 : "");
        bool third_party = (isThirdParty != 0);
        return current_impl->should_block_ex(url, source_host, request_type, third_party) ? 1 : 0;
    }
    return 0;
}

// Same as aurora_adblock_should_block_ex plus isSameHost: when isSameHost is
// nonzero, host-only DomainMatch rules are skipped (they never fire) while
// path-prefix/contains/regex/anchored rules still evaluate.
EXPORT int aurora_adblock_should_block_ex2(
    void* engine, 
    const char* urlUtf8, 
    const char* sourceHostUtf8, 
    const char* requestTypeUtf8, 
    int isThirdParty,
    int isSameHost
) {
    if (!engine || !urlUtf8) return 0;
    auto* wrapper = static_cast<AdBlockEngineWrapper*>(engine);
    
    std::shared_ptr<AdBlockEngineImpl> current_impl;
    {
        std::lock_guard<std::mutex> lock(wrapper->mutex);
        current_impl = wrapper->impl;
    }
    
    if (current_impl) {
        std::string_view url(urlUtf8);
        std::string_view source_host(sourceHostUtf8 ? sourceHostUtf8 : "");
        std::string_view request_type(requestTypeUtf8 ? requestTypeUtf8 : "");
        bool third_party = (isThirdParty != 0);
        bool same_host = (isSameHost != 0);
        return current_impl->should_block_ex2(url, source_host, request_type, third_party, same_host) ? 1 : 0;
    }
    return 0;
}

EXPORT int aurora_adblock_should_hide_element(
    void* engine,
    const char* pageHostUtf8,
    const char* tagNameUtf8,
    const char* idUtf8,
    const char* classesUtf8
) {
    if (!engine || !pageHostUtf8) return 0;
    auto* wrapper = static_cast<AdBlockEngineWrapper*>(engine);
    
    std::shared_ptr<AdBlockEngineImpl> current_impl;
    {
        std::lock_guard<std::mutex> lock(wrapper->mutex);
        current_impl = wrapper->impl;
    }
    
    if (current_impl) {
        std::string_view host(pageHostUtf8);
        std::string_view tag(tagNameUtf8 ? tagNameUtf8 : "");
        std::string_view id(idUtf8 ? idUtf8 : "");

        // Split the whitespace-delimited class list into string_views (the
        // old code built a std::vector<std::string> + stringstream per call).
        std::vector<std::string_view> classes;
        if (classesUtf8 != nullptr) {
            std::string_view classes_str(classesUtf8);
            size_t start = 0;
            while (start < classes_str.size()) {
                // Skip leading whitespace (matches `while (ss >> cls)`).
                while (start < classes_str.size() &&
                       std::isspace(static_cast<unsigned char>(classes_str[start]))) {
                    ++start;
                }
                size_t end = start;
                while (end < classes_str.size() &&
                       !std::isspace(static_cast<unsigned char>(classes_str[end]))) {
                    ++end;
                }
                if (end > start) {
                    classes.push_back(classes_str.substr(start, end - start));
                }
                start = end;
            }
        }
        
        return current_impl->should_hide_element(host, tag, id, classes) ? 1 : 0;
    }
    return 0;
}

EXPORT void aurora_adblock_destroy(void* engine) {
    if (!engine) return;
    auto* wrapper = static_cast<AdBlockEngineWrapper*>(engine);
    delete wrapper;
}

}
