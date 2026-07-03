#pragma once
#include <string>
#include <vector>

enum class RuleType {
    DomainMatch,      // ||domain.com^
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

struct Rule {
    RuleType type;
    std::string pattern;      // The original or processed pattern to match
    bool is_exception;
    std::string domain;       // Extracted domain for DomainMatch/AnchoredStart optimization
    
    // Option modifiers
    bool has_options = false;
    bool option_third_party = false;
    bool option_not_third_party = false;
    unsigned int type_mask = 0;
    unsigned int type_exclude_mask = 0;
    std::vector<std::pair<std::string, bool>> domain_modifiers; // {domain, is_include}
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
    static bool looks_host_like(const std::string& host);
};
