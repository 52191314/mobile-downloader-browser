#include "adblock_engine.h"
#include <mutex>
#include <memory>
#include <vector>
#include <sstream>

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
        return current_impl->should_block_ex(std::string(urlUtf8), "", "", false) ? 1 : 0;
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
        std::string url(urlUtf8);
        std::string source_host(sourceHostUtf8 ? sourceHostUtf8 : "");
        std::string request_type(requestTypeUtf8 ? requestTypeUtf8 : "");
        bool third_party = (isThirdParty != 0);
        return current_impl->should_block_ex(url, source_host, request_type, third_party) ? 1 : 0;
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
        std::string host(pageHostUtf8);
        std::string tag(tagNameUtf8 ? tagNameUtf8 : "");
        std::string id(idUtf8 ? idUtf8 : "");
        std::string classes_str(classesUtf8 ? classesUtf8 : "");
        
        std::vector<std::string> classes;
        std::stringstream ss(classes_str);
        std::string cls;
        while (ss >> cls) {
            classes.push_back(cls);
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
