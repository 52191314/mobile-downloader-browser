#pragma once
#include "url_matcher.h"
#include <string>
#include <string_view>
#include <memory>

class AdBlockEngineImpl {
public:
    AdBlockEngineImpl();
    ~AdBlockEngineImpl();

    void load_rules(const std::string& rules_text);
    
    bool should_block_ex(
        std::string_view url, 
        std::string_view source_host, 
        std::string_view request_type, 
        bool is_third_party
    ) const;
    
    bool should_hide_element(
        std::string_view page_host,
        std::string_view tag_name,
        std::string_view id,
        const std::vector<std::string_view>& classes
    ) const;

private:
    URLMatcher matcher_;
};
