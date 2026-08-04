#include "adblock_engine.h"
#include "rule_parser.h"

AdBlockEngineImpl::AdBlockEngineImpl() {}
AdBlockEngineImpl::~AdBlockEngineImpl() {}

void AdBlockEngineImpl::load_rules(const std::string& rules_text) {
    std::vector<Rule> network_rules;
    std::vector<CosmeticRule> cosmetic_rules;
    RuleParser::parse_filter_text(rules_text, network_rules, cosmetic_rules);
    matcher_.compile(network_rules, cosmetic_rules);
}

bool AdBlockEngineImpl::should_block_ex(
    std::string_view url, 
    std::string_view source_host, 
    std::string_view request_type, 
    bool is_third_party
) const {
    return matcher_.should_block_ex(url, source_host, request_type, is_third_party);
}

bool AdBlockEngineImpl::should_hide_element(
    std::string_view page_host,
    std::string_view tag_name,
    std::string_view id,
    const std::vector<std::string_view>& classes
) const {
    return matcher_.should_hide_element(page_host, tag_name, id, classes);
}
