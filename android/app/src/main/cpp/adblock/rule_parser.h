#pragma once
#include <string>
#include <vector>

enum class RuleType {
    DomainMatch,      // ||domain.com^  (host-only, matched via the domain trie)
    PathPrefix,       // ||domain.com/path... (URL prefix after the scheme, host-indexed)
    AnchoredStart,    // |http://...
    AnchoredEnd,      // ...|
    ExactMatch,       // |http://example.com/|
    Contains,         // *pattern* or pattern
    Regex             // /regex/
};

// Request type bits
constexpr unsigned int TYPE_SCRIPT = 1 << 0;
constexpr unsigned int TYPE_IMAGE = 1 << 1;
constexpr unsigned int TYPE_STYLESHEET = 1 << 2;
constexpr unsigned int TYPE_XMLHTTPREQUEST = 1 << 3;
constexpr unsigned int TYPE_SUBDOCUMENT = 1 << 4;
constexpr unsigned int TYPE_OTHER = 1 << 5;
constexpr unsigned int TYPE_MEDIA = 1 << 6;
constexpr unsigned int TYPE_POPUP = 1 << 7;
constexpr unsigned int TYPE_FONT = 1 << 8;
constexpr unsigned int TYPE_PING = 1 << 9;
constexpr unsigned int TYPE_WEBSOCKET = 1 << 10;

struct Rule {
    RuleType type;
    std::string pattern;      // The original or processed pattern to match
    bool is_exception;
    std::string domain;       // Extracted domain for DomainMatch/PathPrefix/AnchoredStart optimization
    
    // Option modifiers
    bool has_options = false;
    bool option_third_party = false;
    bool option_not_third_party = false;
    unsigned int type_mask = 0;
    unsigned int type_exclude_mask = 0;
    std::vector<std::pair<std::string, bool>> domain_modifiers; // {domain, is_include}
    
    // Extended options
    std::vector<std::string> denyallow_list;   // $denyallow=a|b -- rule skipped when the request host matches
    bool important = false;      // $important -- blocking rules with this flag override exception rules
    bool badfilter = false;      // $badfilter -- drops previously parsed rules with identical pattern+options
    bool elemhide = false;       // $elemhide -- parsed only (cosmetic gating happens on the Dart side)
    bool generichide = false;    // $generichide -- parsed only
    bool case_sensitive = false; // $match-case -- literal patterns default to case-insensitive
    bool match_case_explicit = false; // set when $match-case / ~$match-case was written
    bool trailing_exact = false; // pattern ends with '|' -- the URL must end right after the prefix
};

struct CosmeticRule {
    std::string selector;
    bool is_exception;
    std::vector<std::pair<std::string, bool>> domain_modifiers; // {domain, is_include}
};

class RuleParser {
public:
    static void parse_filter_text(
        const std::string& rules_text,
        std::vector<Rule>& network_rules,
        std::vector<CosmeticRule>& cosmetic_rules
    );
    static std::string glob_to_regex(const std::string& glob);
    static std::string hostname_anchor_to_regex(const std::string& rest);
    static bool looks_host_like(const std::string& host);
};
