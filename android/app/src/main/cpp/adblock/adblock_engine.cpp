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
    const std::string& url, 
    const std::string& source_host, 
    const std::string& request_type, 
    bool is_third_party
) const {
    return matcher_.should_block_ex(url, source_host, request_type, is_third_party);
}

bool AdBlockEngineImpl::should_hide_element(
    const std::string& page_host,
    const std::string& tag_name,
    const std::string& id,
    const std::vector<std::string>& classes
) const {
    return matcher_.should_hide_element(page_host, tag_name, id, classes);
}
