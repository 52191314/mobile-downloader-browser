#pragma once
#include "url_matcher.h"
#include <string>
#include <memory>

class AdBlockEngineImpl {
public:
    AdBlockEngineImpl();
    ~AdBlockEngineImpl();

    void load_rules(const std::string& rules_text);
    
    bool should_block_ex(
        const std::string& url, 
        const std::string& source_host, 
        const std::string& request_type, 
        bool is_third_party
    ) const;
    
    bool should_hide_element(
        const std::string& page_host,
        const std::string& tag_name,
        const std::string& id,
        const std::vector<std::string>& classes
    ) const;

private:
    URLMatcher matcher_;
};
