#include "url_matcher.h"
#include <sstream>
#include <algorithm>
#include <queue>
#include <cctype>

// RegexCache implementation
RegexCache::RegexCache(size_t capacity) : capacity_(capacity) {}

bool RegexCache::match(const std::string& pattern, std::string_view text) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = cache_.find(pattern);
    if (it != cache_.end()) {
        lru_list_.splice(lru_list_.begin(), lru_list_, it->second);
        try {
            return std::regex_search(text.begin(), text.end(), it->second->re);
        } catch (...) {
            return false;
        }
    }
    
    try {
        std::regex re(pattern, std::regex::ECMAScript | std::regex::optimize);
        if (lru_list_.size() >= capacity_) {
            auto last = lru_list_.back();
            cache_.erase(last.pattern);
            lru_list_.pop_back();
        }
        lru_list_.push_front({pattern, re});
        cache_[pattern] = lru_list_.begin();
        return std::regex_search(text.begin(), text.end(), re);
    } catch (...) {
        return false;
    }
}

// Helper to split domain components
static std::vector<std::string> split_domain(const std::string& domain) {
    std::vector<std::string> parts;
    std::stringstream ss(domain);
    std::string part;
    while (std::getline(ss, part, '.')) {
        if (!part.empty()) {
            parts.push_back(part);
        }
    }
    return parts;
}

static bool evaluate_domain_modifiers(const std::vector<std::pair<std::string, bool>>& modifiers, std::string_view host) {
    if (modifiers.empty()) return true;
    bool has_positive = false;
    bool matched_positive = false;
    bool matched_negative = false;
    for (const auto& [mod_domain, is_include] : modifiers) {
        bool is_match = (host == mod_domain || 
                         (host.size() > mod_domain.size() && 
                          host.substr(host.size() - mod_domain.size() - 1) == "." + mod_domain));
        if (is_include) {
            has_positive = true;
            if (is_match) matched_positive = true;
        } else {
            if (is_match) matched_negative = true;
        }
    }
    if (matched_negative) return false;
    if (has_positive && !matched_positive) return false;
    return true;
}

static bool selector_matches(
    const std::string& selector,
    std::string_view tag_name,
    std::string_view id,
    const std::vector<std::string_view>& classes
) {
    std::string clean = selector;
    // Trim
    clean.erase(clean.begin(), std::find_if(clean.begin(), clean.end(), [](unsigned char ch) {
        return !std::isspace(ch);
    }));
    clean.erase(std::find_if(clean.rbegin(), clean.rend(), [](unsigned char ch) {
        return !std::isspace(ch);
    }).base(), clean.end());
    
    if (clean.empty()) return false;
    
    if (clean[0] == '#') {
        return id == clean.substr(1);
    }
    if (clean[0] == '.') {
        std::string cls = clean.substr(1);
        return std::find(classes.begin(), classes.end(), cls) != classes.end();
    }
    
    std::string tag = std::string(tag_name);
    std::transform(tag.begin(), tag.end(), tag.begin(), [](unsigned char c) { return std::tolower(c); });
    
    if (clean.find('.') == std::string::npos && clean.find('#') == std::string::npos) {
        std::string l_selector = clean;
        std::transform(l_selector.begin(), l_selector.end(), l_selector.begin(), [](unsigned char c) { return std::tolower(c); });
        return tag == l_selector;
    }
    
    size_t dot_pos = clean.find('.');
    if (dot_pos != std::string::npos && dot_pos > 0 && dot_pos < clean.size() - 1) {
        std::string tag_part = clean.substr(0, dot_pos);
        std::string class_part = clean.substr(dot_pos + 1);
        std::transform(tag_part.begin(), tag_part.end(), tag_part.begin(), [](unsigned char c) { return std::tolower(c); });
        if (tag == tag_part) {
            return std::find(classes.begin(), classes.end(), class_part) != classes.end();
        }
    }
    return false;
}

URLMatcher::URLMatcher() : trie_root_(nullptr) {}
URLMatcher::~URLMatcher() {
    clear();
}

void URLMatcher::clear() {
    rules_.clear();
    cosmetic_rules_.clear();
    trie_root_.reset();
    ac_nodes_.clear();
    regex_exceptions_.clear();
    regex_blocks_.clear();
    general_anchored_exceptions_.clear();
    general_anchored_blocks_.clear();
    cosmetic_exceptions_.clear();
    cosmetic_blocks_.clear();
}

void URLMatcher::compile(const std::vector<Rule>& rules, const std::vector<CosmeticRule>& cosmetic_rules) {
    clear();
    rules_ = rules;
    cosmetic_rules_ = cosmetic_rules;
    
    trie_root_ = std::make_unique<TrieNode>();
    
    struct ACPattern {
        std::string pattern;
        const Rule* rule;
    };
    std::vector<ACPattern> ac_patterns;
    
    for (const auto& rule : rules_) {
        if (rule.type == RuleType::DomainMatch) {
            std::vector<std::string> parts = split_domain(rule.domain);
            std::reverse(parts.begin(), parts.end());
            
            TrieNode* curr = trie_root_.get();
            for (const auto& part : parts) {
                if (curr->children.find(part) == curr->children.end()) {
                    curr->children[part] = std::make_unique<TrieNode>();
                }
                curr = curr->children[part].get();
            }
            curr->rules.push_back(&rule);
        } else if (rule.type == RuleType::AnchoredStart) {
            if (!rule.domain.empty()) {
                std::vector<std::string> parts = split_domain(rule.domain);
                std::reverse(parts.begin(), parts.end());
                
                TrieNode* curr = trie_root_.get();
                for (const auto& part : parts) {
                    if (curr->children.find(part) == curr->children.end()) {
                        curr->children[part] = std::make_unique<TrieNode>();
                    }
                    curr = curr->children[part].get();
                }
                curr->rules.push_back(&rule);
            } else {
                if (rule.is_exception) {
                    general_anchored_exceptions_.push_back(&rule);
                } else {
                    general_anchored_blocks_.push_back(&rule);
                }
            }
        } else if (rule.type == RuleType::AnchoredEnd) {
            if (rule.is_exception) {
                general_anchored_exceptions_.push_back(&rule);
            } else {
                general_anchored_blocks_.push_back(&rule);
            }
        } else if (rule.type == RuleType::ExactMatch) {
            if (rule.is_exception) {
                general_anchored_exceptions_.push_back(&rule);
            } else {
                general_anchored_blocks_.push_back(&rule);
            }
        } else if (rule.type == RuleType::Contains) {
            ac_patterns.push_back({rule.pattern, &rule});
        } else if (rule.type == RuleType::Regex) {
            if (rule.is_exception) {
                regex_exceptions_.push_back(&rule);
            } else {
                regex_blocks_.push_back(&rule);
            }
        }
    }
    
    for (const auto& rule : cosmetic_rules_) {
        if (rule.is_exception) {
            cosmetic_exceptions_.push_back(&rule);
        } else {
            cosmetic_blocks_.push_back(&rule);
        }
    }
    
    if (!ac_patterns.empty()) {
        ac_nodes_.emplace_back();
        for (const auto& ac_pat : ac_patterns) {
            if (ac_pat.pattern.empty()) continue;
            int curr = 0;
            for (char c : ac_pat.pattern) {
                char lc = std::tolower(static_cast<unsigned char>(c));
                if (ac_nodes_[curr].children.find(lc) == ac_nodes_[curr].children.end()) {
                    ac_nodes_[curr].children[lc] = ac_nodes_.size();
                    ac_nodes_.emplace_back();
                }
                curr = ac_nodes_[curr].children[lc];
            }
            ac_nodes_[curr].rules.push_back(ac_pat.rule);
        }
        build_aho_corasick();
    }
}

void URLMatcher::build_aho_corasick() {
    std::queue<int> q;
    for (auto const& [c, child_idx] : ac_nodes_[0].children) {
        ac_nodes_[child_idx].fail = 0;
        q.push(child_idx);
    }
    
    while (!q.empty()) {
        int curr = q.front();
        q.pop();
        
        for (auto const& [c, child_idx] : ac_nodes_[curr].children) {
            int fail_node = ac_nodes_[curr].fail;
            while (fail_node != 0 && ac_nodes_[fail_node].children.find(c) == ac_nodes_[fail_node].children.end()) {
                fail_node = ac_nodes_[fail_node].fail;
            }
            
            if (ac_nodes_[fail_node].children.find(c) != ac_nodes_[fail_node].children.end()) {
                ac_nodes_[child_idx].fail = ac_nodes_[fail_node].children[c];
            } else {
                ac_nodes_[child_idx].fail = 0;
            }
            
            int fail_target = ac_nodes_[child_idx].fail;
            if (!ac_nodes_[fail_target].rules.empty()) {
                ac_nodes_[child_idx].output_link = fail_target;
            } else {
                ac_nodes_[child_idx].output_link = ac_nodes_[fail_target].output_link;
            }
            
            q.push(child_idx);
        }
    }
}

std::string URLMatcher::extract_host(std::string_view url) const {
    std::string host = std::string(url);
    size_t scheme_pos = host.find("://");
    if (scheme_pos != std::string::npos) {
        host = host.substr(scheme_pos + 3);
    } else if (host.rfind("//", 0) == 0) {
        host = host.substr(2);
    }
    
    size_t sep_pos = host.find_first_of("/:?#");
    if (sep_pos != std::string::npos) {
        host = host.substr(0, sep_pos);
    }
    
    size_t at_pos = host.find('@');
    if (at_pos != std::string::npos) {
        host = host.substr(at_pos + 1);
    }
    
    for (char& c : host) {
        c = std::tolower(static_cast<unsigned char>(c));
    }
    return host;
}

bool URLMatcher::evaluate_options(
    const Rule* rule, 
    std::string_view source_host, 
    std::string_view request_type, 
    bool is_third_party
) const {
    if (!rule->has_options) return true;
    
    if (rule->option_third_party && !is_third_party) return false;
    if (rule->option_not_third_party && is_third_party) return false;
    
    if (rule->type_mask != 0 || rule->type_exclude_mask != 0) {
        unsigned int type_bit = TYPE_OTHER;
        if (request_type == "script") type_bit = TYPE_SCRIPT;
        else if (request_type == "image") type_bit = TYPE_IMAGE;
        else if (request_type == "stylesheet") type_bit = TYPE_STYLESHEET;
        else if (request_type == "xmlhttprequest") type_bit = TYPE_XMLHTTPREQUEST;
        else if (request_type == "subdocument") type_bit = TYPE_SUBDOCUMENT;
        
        if (rule->type_mask != 0 && !(rule->type_mask & type_bit)) return false;
        if (rule->type_exclude_mask != 0 && (rule->type_exclude_mask & type_bit)) return false;
    }
    
    if (!rule->domain_modifiers.empty()) {
        if (!evaluate_domain_modifiers(rule->domain_modifiers, source_host)) {
            return false;
        }
    }
    
    return true;
}

bool URLMatcher::should_block_ex(
    std::string_view url, 
    std::string_view source_host, 
    std::string_view request_type, 
    bool is_third_party
) const {
    if (url.empty()) return false;
    
    std::string lc_url = std::string(url);
    std::transform(lc_url.begin(), lc_url.end(), lc_url.begin(), [](unsigned char c) {
        return std::tolower(c);
    });
    
    std::string host = extract_host(url);
    bool blocked = false;
    
    auto evaluate_rule = [&](const Rule* rule) -> bool {
        if (!evaluate_options(rule, source_host, request_type, is_third_party)) {
            return false;
        }
        
        if (rule->type == RuleType::DomainMatch) {
            return true;
        } else if (rule->type == RuleType::AnchoredStart) {
            if (lc_url.size() >= rule->pattern.size()) {
                std::string pat = rule->pattern;
                std::transform(pat.begin(), pat.end(), pat.begin(), [](unsigned char c) { return std::tolower(c); });
                return lc_url.compare(0, pat.size(), pat) == 0;
            }
            return false;
        } else if (rule->type == RuleType::AnchoredEnd) {
            if (lc_url.size() >= rule->pattern.size()) {
                std::string pat = rule->pattern;
                std::transform(pat.begin(), pat.end(), pat.begin(), [](unsigned char c) { return std::tolower(c); });
                return lc_url.compare(lc_url.size() - pat.size(), pat.size(), pat) == 0;
            }
            return false;
        } else if (rule->type == RuleType::ExactMatch) {
            if (url.size() == rule->pattern.size()) {
                std::string pat = rule->pattern;
                std::transform(pat.begin(), pat.end(), pat.begin(), [](unsigned char c) { return std::tolower(c); });
                return lc_url == pat;
            }
            return false;
        } else if (rule->type == RuleType::Regex) {
            return regex_cache_.match(rule->pattern, url);
        }
        return false;
    };

    // 1. Domain Trie exceptions
    if (!host.empty()) {
        std::vector<std::string> parts = split_domain(host);
        std::reverse(parts.begin(), parts.end());
        
        const TrieNode* curr = trie_root_.get();
        for (const auto& part : parts) {
            if (!curr) break;
            auto it = curr->children.find(part);
            if (it != curr->children.end()) {
                curr = it->second.get();
                for (const Rule* rule : curr->rules) {
                    if (rule->is_exception && evaluate_rule(rule)) {
                        return false;
                    }
                }
            } else {
                curr = nullptr;
            }
        }
    }
    
    // 2. Aho-Corasick contains exceptions and blocks
    if (!ac_nodes_.empty()) {
        int curr = 0;
        for (char c : lc_url) {
            while (curr != 0 && ac_nodes_[curr].children.find(c) == ac_nodes_[curr].children.end()) {
                curr = ac_nodes_[curr].fail;
            }
            const auto it = ac_nodes_[curr].children.find(c);
            if (it != ac_nodes_[curr].children.end()) {
                curr = it->second;
            } else {
                curr = 0;
            }
            
            int check = curr;
            while (check != 0) {
                for (const Rule* rule : ac_nodes_[check].rules) {
                    if (rule->is_exception) {
                        if (evaluate_rule(rule)) {
                            return false;
                        }
                    } else {
                        if (evaluate_rule(rule)) {
                            blocked = true;
                        }
                    }
                }
                check = ac_nodes_[check].output_link;
            }
        }
    }
    
    // 3. General anchored exceptions
    for (const Rule* rule : general_anchored_exceptions_) {
        if (evaluate_rule(rule)) {
            return false;
        }
    }
    
    // 4. Regex exceptions
    for (const Rule* rule : regex_exceptions_) {
        if (evaluate_rule(rule)) {
            return false;
        }
    }
    
    if (blocked) {
        return true;
    }
    
    // 5. Domain Trie blocks
    if (!host.empty()) {
        std::vector<std::string> parts = split_domain(host);
        std::reverse(parts.begin(), parts.end());
        
        const TrieNode* curr = trie_root_.get();
        for (const auto& part : parts) {
            if (!curr) break;
            auto it = curr->children.find(part);
            if (it != curr->children.end()) {
                curr = it->second.get();
                for (const Rule* rule : curr->rules) {
                    if (!rule->is_exception && evaluate_rule(rule)) {
                        return true;
                    }
                }
            } else {
                curr = nullptr;
            }
        }
    }
    
    // 6. General anchored blocks
    for (const Rule* rule : general_anchored_blocks_) {
        if (evaluate_rule(rule)) {
            return true;
        }
    }
    
    // 7. Regex blocks
    for (const Rule* rule : regex_blocks_) {
        if (evaluate_rule(rule)) {
            return true;
        }
    }
    
    return false;
}

bool URLMatcher::should_hide_element(
    std::string_view page_host,
    std::string_view tag_name,
    std::string_view id,
    const std::vector<std::string_view>& classes
) const {
    std::string host = std::string(page_host);
    std::transform(host.begin(), host.end(), host.begin(), [](unsigned char c) { return std::tolower(c); });
    
    // Exceptions first
    for (const CosmeticRule* rule : cosmetic_exceptions_) {
        if (evaluate_domain_modifiers(rule->domain_modifiers, host)) {
            if (selector_matches(rule->selector, tag_name, id, classes)) {
                return false;
            }
        }
    }
    
    // Blocks
    for (const CosmeticRule* rule : cosmetic_blocks_) {
        if (evaluate_domain_modifiers(rule->domain_modifiers, host)) {
            if (selector_matches(rule->selector, tag_name, id, classes)) {
                return true;
            }
        }
    }
    
    return false;
}
