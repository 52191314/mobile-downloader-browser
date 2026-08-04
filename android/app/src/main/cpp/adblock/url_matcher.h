#pragma once
#include "rule_parser.h"
#include <string>
#include <string_view>
#include <vector>
#include <memory>
#include <unordered_map>
#include <regex>
#include <mutex>
#include <list>

// Regex cache entry
struct RegexCacheEntry {
    std::string pattern;
    std::regex re;
};

class RegexCache {
public:
    explicit RegexCache(size_t capacity = 100);
    bool match(const std::string& pattern, std::string_view text);

private:
    size_t capacity_;
    std::mutex mutex_;
    std::list<RegexCacheEntry> lru_list_;
    std::unordered_map<std::string, std::list<RegexCacheEntry>::iterator> cache_;
};

// Domain trie node
struct TrieNode {
    std::unordered_map<std::string, std::unique_ptr<TrieNode>> children;
    std::vector<const Rule*> rules;
};

// Aho-Corasick node
struct ACNode {
    std::unordered_map<char, int> children;
    int fail = 0;
    int output_link = 0;
    std::vector<const Rule*> rules;
};

class URLMatcher {
public:
    URLMatcher();
    ~URLMatcher();

    void compile(const std::vector<Rule>& rules, const std::vector<CosmeticRule>& cosmetic_rules);
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
    std::string extract_host(std::string_view url) const;
    void build_aho_corasick();
    void clear();
    
    bool evaluate_options(const Rule* rule, std::string_view source_host, std::string_view request_type, bool is_third_party) const;

    std::vector<Rule> rules_;
    std::vector<CosmeticRule> cosmetic_rules_;
    
    // Domain Trie (reversed domain components)
    std::unique_ptr<TrieNode> trie_root_;
    
    // Aho-Corasick structures
    std::vector<ACNode> ac_nodes_;
    
    // Regex rules
    std::vector<const Rule*> regex_exceptions_;
    std::vector<const Rule*> regex_blocks_;
    
    // General anchored rules
    std::vector<const Rule*> general_anchored_exceptions_;
    std::vector<const Rule*> general_anchored_blocks_;

    // Cosmetic rules categorized
    std::vector<const CosmeticRule*> cosmetic_exceptions_;
    std::vector<const CosmeticRule*> cosmetic_blocks_;

    // Mutable regex cache
    mutable RegexCache regex_cache_;
};
