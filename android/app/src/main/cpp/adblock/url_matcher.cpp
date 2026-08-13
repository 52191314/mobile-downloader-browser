#include "url_matcher.h"
#include <sstream>
#include <algorithm>
#include <queue>
#include <cctype>
#include <unordered_map>

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

// True when `host` equals `domain` or is a subdomain of it (dot-boundary,
// so "notexample.com" never matches "example.com").
static bool host_matches(std::string_view host, const std::string& domain) {
    if (host == domain) return true;
    return host.size() > domain.size() &&
           host.compare(host.size() - domain.size() - 1, domain.size() + 1, "." + domain) == 0;
}

// ABP/uBO separator: '^' matches the end of the URL or any single char that
// is NOT in [A-Za-z0-9_-.%].
static inline bool is_separator(char c) {
    return !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
             (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.' || c == '%');
}

// Forward scan: matches pattern[p0..] against text[t0..] as a prefix,
// consuming exactly the whole pattern. '^' consumes one separator char, or
// matches zero-width at the end of `text` (end of URL). Sets t_end to the
// text position right after the match.
static bool match_fwd(std::string_view text, size_t t0, std::string_view pattern, size_t p0, size_t& t_end) {
    size_t t = t0, p = p0;
    while (p < pattern.size()) {
        char pc = pattern[p];
        if (pc == '^') {
            if (t >= text.size()) {
                ++p;  // zero-width: '^' matches the end of the URL
                continue;
            }
            if (is_separator(text[t])) {
                ++t;
                ++p;
                continue;
            }
            return false;
        }
        if (t >= text.size() || text[t] != pc) return false;
        ++t;
        ++p;
    }
    t_end = t;
    return true;
}

// Backward scan with backtracking: matches pattern[0..p) against the text
// region ending at `t` (text[0..t)), walking backwards. '^' consumes one
// separator char immediately before position t, or -- only at the true end of
// the URL -- matches zero-width.
static bool match_bwd(std::string_view text, size_t t, std::string_view pattern, size_t p) {
    while (p > 0) {
        char pc = pattern[p - 1];
        if (pc == '^') {
            if (t > 0 && is_separator(text[t - 1])) {
                if (match_bwd(text, t - 1, pattern, p - 1)) return true;
            }
            if (t == text.size()) {
                // Zero-width: '^' matches the end of the URL.
                return match_bwd(text, t, pattern, p - 1);
            }
            return false;
        }
        if (t == 0 || text[t - 1] != pc) return false;
        --t;
        --p;
    }
    return true;
}

static bool match_bwd(std::string_view text, std::string_view pattern) {
    return match_bwd(text, text.size(), pattern, pattern.size());
}

static bool evaluate_domain_modifiers(const std::vector<std::pair<std::string, bool>>& modifiers, std::string_view host) {
    if (modifiers.empty()) return true;
    bool has_positive = false;
    bool matched_positive = false;
    bool matched_negative = false;
    for (const auto& [mod_domain, is_include] : modifiers) {
        bool is_match = host_matches(host, mod_domain);
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

// Canonical signature of a rule's pattern+options, used by $badfilter to drop
// previously parsed rules with an identical signature. The badfilter flag
// itself is deliberately excluded so a $badfilter rule's signature equals the
// signature of the rules it targets.
static std::string rule_signature(const Rule& r) {
    std::string sig;
    sig.reserve(64);
    sig += r.is_exception ? 'E' : 'B';
    sig += static_cast<char>('0' + static_cast<int>(r.type));
    sig += '|';
    sig += r.pattern;
    sig += '|';
    sig += r.domain;
    sig += '|';
    // Note: every option below emits its own marker, so no separate
    // has_options bit is needed -- and the $badfilter flag itself must not
    // change the signature (a $badfilter rule's signature equals the signature
    // of the rules it targets, which may have no options at all).
    if (r.option_third_party) sig += ",3p";
    if (r.option_not_third_party) sig += ",n3p";
    if (r.type_mask != 0) { sig += ",t+"; sig += std::to_string(r.type_mask); }
    if (r.type_exclude_mask != 0) { sig += ",t-"; sig += std::to_string(r.type_exclude_mask); }
    for (const auto& dm : r.domain_modifiers) {
        sig += ",dm";
        sig += dm.second ? '+' : '-';
        sig += dm.first;
    }
    for (const auto& da : r.denyallow_list) { sig += ",da"; sig += da; }
    if (r.important) sig += ",imp";
    if (r.case_sensitive) sig += ",mc";
    if (r.elemhide) sig += ",eh";
    if (r.generichide) sig += ",gh";
    if (r.trailing_exact) sig += ",tE";
    return sig;
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
    
    // $badfilter hygiene: a $badfilter rule drops previously parsed rules
    // with an identical pattern+options signature (list patches like AdGuard's
    // "Quick fixes" rely on this). The badfilter rule itself never compiles.
    {
        std::unordered_map<std::string, std::vector<size_t>> sig_indices;
        std::vector<bool> drop(rules_.size(), false);
        for (size_t i = 0; i < rules_.size(); ++i) {
            const Rule& r = rules_[i];
            if (r.badfilter) {
                auto it = sig_indices.find(rule_signature(r));
                if (it != sig_indices.end()) {
                    for (size_t idx : it->second) drop[idx] = true;
                }
                drop[i] = true;
            } else {
                sig_indices[rule_signature(r)].push_back(i);
            }
        }
        size_t w = 0;
        for (size_t i = 0; i < rules_.size(); ++i) {
            if (!drop[i]) rules_[w++] = rules_[i];
        }
        rules_.resize(w);
    }
    
    trie_root_ = std::make_unique<TrieNode>();
    
    struct ACPattern {
        std::string pattern;
        const Rule* rule;
    };
    std::vector<ACPattern> ac_patterns;
    
    for (const auto& rule : rules_) {
        if (rule.type == RuleType::DomainMatch || rule.type == RuleType::PathPrefix) {
            // PathPrefix rules are host-indexed by their domain like plain
            // DomainMatch rules; the path-prefix + separator check happens in
            // the per-request evaluation (evaluate_rule).
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
    std::string_view request_host,
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
        else if (request_type == "media") type_bit = TYPE_MEDIA;
        else if (request_type == "popup") type_bit = TYPE_POPUP;
        else if (request_type == "font") type_bit = TYPE_FONT;
        else if (request_type == "ping") type_bit = TYPE_PING;
        else if (request_type == "websocket") type_bit = TYPE_WEBSOCKET;
        else if (request_type == "other") type_bit = TYPE_OTHER;
        
        if (rule->type_mask != 0 && !(rule->type_mask & type_bit)) return false;
        if (rule->type_exclude_mask != 0 && (rule->type_exclude_mask & type_bit)) return false;
    }
    
    if (!rule->domain_modifiers.empty()) {
        if (!evaluate_domain_modifiers(rule->domain_modifiers, source_host)) {
            return false;
        }
    }
    
    if (!rule->denyallow_list.empty()) {
        // $denyallow=a|b -- the rule only applies when the request host is NOT
        // in the denyallow list.
        for (const auto& deny_domain : rule->denyallow_list) {
            if (host_matches(request_host, deny_domain)) {
                return false;
            }
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
    return should_block_ex2(url, source_host, request_type, is_third_party, false);
}

bool URLMatcher::should_block_ex2(
    std::string_view url, 
    std::string_view source_host, 
    std::string_view request_type, 
    bool is_third_party,
    bool skip_host_only
) const {
    if (url.empty()) return false;
    
    std::string lc_url = std::string(url);
    std::transform(lc_url.begin(), lc_url.end(), lc_url.begin(), [](unsigned char c) {
        return std::tolower(c);
    });
    std::string_view lc_url_view(lc_url);
    
    // Scheme-stripped views for PathPrefix comparisons (mirrors
    // extract_host's scheme handling).
    std::string_view lc_path = lc_url_view;
    size_t scheme_pos = lc_url.find("://");
    if (scheme_pos != std::string::npos) {
        lc_path = lc_url_view.substr(scheme_pos + 3);
    } else if (lc_url.rfind("//", 0) == 0) {
        lc_path = lc_url_view.substr(2);
    }
    std::string_view raw_path = url;
    size_t raw_scheme_pos = url.find("://");
    if (raw_scheme_pos != std::string::npos) {
        raw_path = raw_path.substr(raw_scheme_pos + 3);
    } else if (url.rfind("//", 0) == 0) {
        raw_path = raw_path.substr(2);
    }
    
    std::string host = extract_host(url);
    
    bool blocked = false;
    bool important_blocked = false;
    bool exception_match = false;
    
    auto evaluate_rule = [&](const Rule* rule) -> bool {
        if (!evaluate_options(rule, source_host, host, request_type, is_third_party)) {
            return false;
        }
        
        switch (rule->type) {
            case RuleType::DomainMatch:
                // Reached via the domain trie: the request host already matched.
                return true;
            case RuleType::PathPrefix: {
                if (rule->case_sensitive) {
                    // $match-case: full case-sensitive prefix match against the
                    // scheme-stripped raw URL (pattern keeps its original case).
                    size_t t_end = 0;
                    if (!match_fwd(raw_path, 0, rule->pattern, 0, t_end)) return false;
                    if (rule->trailing_exact && t_end != raw_path.size()) return false;
                    return true;
                }
                // The request host must be the rule domain or a subdomain of it
                // (guaranteed by the trie placement; re-checked for safety) and
                // the URL right after the host must continue with the path.
                if (!host_matches(host, rule->domain)) return false;
                if (rule->pattern.size() <= rule->domain.size()) return false;
                if (lc_path.size() < host.size()) return false;
                std::string_view rest = lc_path.substr(host.size());
                std::string_view path(rule->pattern);
                path = path.substr(rule->domain.size());
                size_t t_end = 0;
                if (!match_fwd(rest, 0, path, 0, t_end)) return false;
                // A trailing '|' in the rule means the URL must end right here.
                if (rule->trailing_exact && t_end != rest.size()) return false;
                return true;
            }
            case RuleType::AnchoredStart: {
                size_t t_end = 0;
                if (rule->case_sensitive) {
                    return match_fwd(url, 0, rule->pattern, 0, t_end);
                }
                return match_fwd(lc_url_view, 0, rule->pattern, 0, t_end);
            }
            case RuleType::AnchoredEnd: {
                if (rule->case_sensitive) {
                    return match_bwd(url, rule->pattern);
                }
                return match_bwd(lc_url_view, rule->pattern);
            }
            case RuleType::ExactMatch: {
                size_t t_end = 0;
                if (rule->case_sensitive) {
                    return match_fwd(url, 0, rule->pattern, 0, t_end) && t_end == url.size();
                }
                return match_fwd(lc_url_view, 0, rule->pattern, 0, t_end) && t_end == lc_url_view.size();
            }
            case RuleType::Regex: {
                if (rule->case_sensitive) {
                    return regex_cache_.match(rule->pattern, url);
                }
                return regex_cache_.match(rule->pattern, lc_url);
            }
            case RuleType::Contains:
                // Reached via the Aho-Corasick automaton, which already
                // verified the case-insensitive substring match against lc_url.
                // (Contains rules are the only rules placed in the automaton,
                // and the parser routes '^'/$match-case patterns to Regex, so
                // a plain contains pattern needs no further checks here.)
                return true;
        }
        return false;
    };
    
    // 1. Domain trie (rules whose domain matches the request host):
    //    DomainMatch, PathPrefix and host-optimized AnchoredStart rules.
    if (!host.empty()) {
        std::vector<std::string> parts = split_domain(host);
        std::reverse(parts.begin(), parts.end());
        
        const TrieNode* curr = trie_root_.get();
        for (const auto& part : parts) {
            if (!curr) break;
            auto it = curr->children.find(part);
            if (it == curr->children.end()) break;
            curr = it->second.get();
            for (const Rule* rule : curr->rules) {
                // skip_host_only: host-only rules never fire (same-host requests).
                if (skip_host_only && rule->type == RuleType::DomainMatch) continue;
                if (evaluate_rule(rule)) {
                    if (rule->is_exception) {
                        exception_match = true;
                    } else {
                        blocked = true;
                        if (rule->important) important_blocked = true;
                    }
                }
            }
        }
    }
    
    // 2. Aho-Corasick contains scan (exceptions and blocks).
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
                    if (evaluate_rule(rule)) {
                        if (rule->is_exception) {
                            exception_match = true;
                        } else {
                            blocked = true;
                            if (rule->important) important_blocked = true;
                        }
                    }
                }
                check = ac_nodes_[check].output_link;
            }
        }
    }
    
    // 3. General anchored rules (no host optimization).
    for (const Rule* rule : general_anchored_exceptions_) {
        if (evaluate_rule(rule)) exception_match = true;
    }
    for (const Rule* rule : general_anchored_blocks_) {
        if (evaluate_rule(rule)) {
            blocked = true;
            if (rule->important) important_blocked = true;
        }
    }
    
    // 4. Regex rules.
    for (const Rule* rule : regex_exceptions_) {
        if (evaluate_rule(rule)) exception_match = true;
    }
    for (const Rule* rule : regex_blocks_) {
        if (evaluate_rule(rule)) {
            blocked = true;
            if (rule->important) important_blocked = true;
        }
    }
    
    // Exceptions override blocks unless an $important block rule matched.
    if (exception_match && !important_blocked) {
        return false;
    }
    return blocked;
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
