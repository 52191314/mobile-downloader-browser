#include "rule_parser.h"
#include <sstream>
#include <algorithm>
#include <cctype>

// Trim from both ends (in-place)
static inline void trim(std::string &s) {
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), [](unsigned char ch) {
        return !std::isspace(ch);
    }));
    s.erase(std::find_if(s.rbegin(), s.rend(), [](unsigned char ch) {
        return !std::isspace(ch);
    }).base(), s.end());
}

static inline std::string to_lower_copy(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return std::tolower(c); });
    return s;
}

static void parse_domain_list(const std::string& domains_str, std::vector<std::pair<std::string, bool>>& domain_modifiers) {
    std::stringstream ss(domains_str);
    std::string domain;
    while (std::getline(ss, domain, ',')) {
        trim(domain);
        if (domain.empty()) continue;
        bool invert = (domain[0] == '~');
        std::string name = invert ? domain.substr(1) : domain;
        std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return std::tolower(c); });
        domain_modifiers.push_back({name, !invert});
    }
}

// ABP/uBO separator: '^' matches the end of the URL or any single char that
// is NOT in [A-Za-z0-9_-.%]. The trailing form also accepts the end of the
// URL, which regex_search represents with '$'.
static const char* const kSepRegexEnd = "(?:[^a-zA-Z0-9_\\-.%]|$)";
static const char* const kSepRegexMid = "[^a-zA-Z0-9_\\-.%]";

// Returns false when the rule carries an option this engine does not support.
// The rule must then be dropped entirely: uBO-only lists use options like
// $redirect/$csp/$jsonprune that this engine cannot honour, and parsing them
// as plain rules would OVER-BLOCK. Unknown option => drop the rule.
static bool parse_options(Rule& rule, const std::string& options_str) {
    rule.has_options = true;
    std::stringstream ss(options_str);
    std::string opt;
    while (std::getline(ss, opt, ',')) {
        trim(opt);
        if (opt.empty()) continue;
        
        bool invert = (opt[0] == '~');
        std::string name = invert ? opt.substr(1) : opt;
        
        if (name == "third-party") {
            if (invert) rule.option_not_third_party = true;
            else rule.option_third_party = true;
        } else if (name == "script") {
            if (invert) rule.type_exclude_mask |= TYPE_SCRIPT;
            else rule.type_mask |= TYPE_SCRIPT;
        } else if (name == "image") {
            if (invert) rule.type_exclude_mask |= TYPE_IMAGE;
            else rule.type_mask |= TYPE_IMAGE;
        } else if (name == "stylesheet") {
            if (invert) rule.type_exclude_mask |= TYPE_STYLESHEET;
            else rule.type_mask |= TYPE_STYLESHEET;
        } else if (name == "xmlhttprequest") {
            if (invert) rule.type_exclude_mask |= TYPE_XMLHTTPREQUEST;
            else rule.type_mask |= TYPE_XMLHTTPREQUEST;
        } else if (name == "subdocument") {
            if (invert) rule.type_exclude_mask |= TYPE_SUBDOCUMENT;
            else rule.type_mask |= TYPE_SUBDOCUMENT;
        } else if (name == "media") {
            if (invert) rule.type_exclude_mask |= TYPE_MEDIA;
            else rule.type_mask |= TYPE_MEDIA;
        } else if (name == "popup") {
            if (invert) rule.type_exclude_mask |= TYPE_POPUP;
            else rule.type_mask |= TYPE_POPUP;
        } else if (name == "font") {
            if (invert) rule.type_exclude_mask |= TYPE_FONT;
            else rule.type_mask |= TYPE_FONT;
        } else if (name == "ping") {
            if (invert) rule.type_exclude_mask |= TYPE_PING;
            else rule.type_mask |= TYPE_PING;
        } else if (name == "websocket") {
            if (invert) rule.type_exclude_mask |= TYPE_WEBSOCKET;
            else rule.type_mask |= TYPE_WEBSOCKET;
        } else if (name == "other") {
            if (invert) rule.type_exclude_mask |= TYPE_OTHER;
            else rule.type_mask |= TYPE_OTHER;
        } else if (name == "match-case") {
            rule.case_sensitive = !invert;
            rule.match_case_explicit = true;
        } else if (name == "important") {
            if (invert) return false;  // ~important is not a supported form
            rule.important = true;
        } else if (name == "badfilter") {
            if (invert) return false;
            rule.badfilter = true;
        } else if (name == "elemhide") {
            // Parsed as a flag only -- cosmetic gating happens on the Dart side.
            if (!invert) rule.elemhide = true;
        } else if (name == "generichide") {
            if (!invert) rule.generichide = true;
        } else if (name.rfind("domain=", 0) == 0) {
            std::string domains_part = name.substr(7);
            std::stringstream dss(domains_part);
            std::string dopt;
            while (std::getline(dss, dopt, '|')) {
                trim(dopt);
                if (dopt.empty()) continue;
                bool d_invert = (dopt[0] == '~');
                std::string d_name = d_invert ? dopt.substr(1) : dopt;
                std::transform(d_name.begin(), d_name.end(), d_name.begin(), [](unsigned char c) { return std::tolower(c); });
                rule.domain_modifiers.push_back({d_name, !d_invert});
            }
        } else if (name.rfind("denyallow=", 0) == 0) {
            if (invert) return false;
            // The rule only applies when the request host is NOT in this list.
            std::string domains_part = name.substr(10);
            std::stringstream dss(domains_part);
            std::string dopt;
            while (std::getline(dss, dopt, '|')) {
                trim(dopt);
                if (dopt.empty()) continue;
                std::transform(dopt.begin(), dopt.end(), dopt.begin(), [](unsigned char c) { return std::tolower(c); });
                rule.denyallow_list.push_back(dopt);
            }
        } else {
            return false;
        }
    }
    return true;
}

void RuleParser::parse_filter_text(
    const std::string& rules_text,
    std::vector<Rule>& network_rules,
    std::vector<CosmeticRule>& cosmetic_rules
) {
    std::stringstream ss(rules_text);
    std::string line;
    
    while (std::getline(ss, line)) {
        trim(line);
        if (line.empty() || line[0] == '!' || line[0] == '[') {
            continue;
        }
        
        // Check if it is a cosmetic rule (contains ## or #@#)
        size_t cosmetic_pos = line.find("##");
        size_t cosmetic_exc_pos = line.find("#@#");
        bool is_cosmetic = (cosmetic_pos != std::string::npos);
        bool is_cosmetic_exc = (cosmetic_exc_pos != std::string::npos);
        
        if (is_cosmetic || is_cosmetic_exc) {
            size_t separator_pos = is_cosmetic ? cosmetic_pos : cosmetic_exc_pos;
            size_t separator_len = is_cosmetic ? 2 : 3;
            
            std::string domain_part = line.substr(0, separator_pos);
            std::string selector_part = line.substr(separator_pos + separator_len);
            
            trim(domain_part);
            trim(selector_part);
            if (selector_part.empty()) continue;
            
            CosmeticRule rule;
            rule.selector = selector_part;
            rule.is_exception = is_cosmetic_exc;
            if (!domain_part.empty()) {
                parse_domain_list(domain_part, rule.domain_modifiers);
            }
            cosmetic_rules.push_back(rule);
            continue;
        }
        
        // Parse network rules
        bool is_exception = false;
        if (line.rfind("@@", 0) == 0) { // starts with @@
            is_exception = true;
            line = line.substr(2);
        }
        
        // --- /regex/ rules are detected before generic option extraction
        // because the pattern may legitimately contain '$' (e.g. /ads\.js$/).
        // A line is a regex rule when it starts with '/', its LAST '/' is the
        // closing delimiter, and everything after that delimiter is either
        // empty or starts with '$' (the options). ---
        if (line.size() >= 2 && line.front() == '/') {
            size_t close = line.rfind('/');
            if (close != std::string::npos && close > 0) {
                std::string after = line.substr(close + 1);
                if (after.empty() || after[0] == '$') {
                    std::string pattern = line.substr(1, close - 1);
                    if (!pattern.empty()) {
                        Rule rule;
                        rule.is_exception = is_exception;
                        std::string options_str = line.substr(close + 1);
                        if (!options_str.empty()) {
                            if (options_str[0] == '$') options_str = options_str.substr(1);
                            if (!parse_options(rule, options_str)) continue;
                        }
                        rule.type = RuleType::Regex;
                        rule.pattern = pattern;
                        // /regex/ rules are case-sensitive by default (ABP);
                        // ~match-case opts into case-insensitive matching.
                        if (rule.match_case_explicit && !rule.case_sensitive) {
                            rule.pattern = to_lower_copy(rule.pattern);
                        } else {
                            rule.case_sensitive = true;
                        }
                        network_rules.push_back(rule);
                        continue;
                    }
                }
            }
        }
        
        // Extract options
        std::string options_str;
        size_t opt_pos = line.find('$');
        if (opt_pos != std::string::npos) {
            options_str = line.substr(opt_pos + 1);
            line = line.substr(0, opt_pos);
        }
        trim(line);
        if (line.empty() || line[0] == '#') {
            continue;
        }
        
        Rule rule;
        rule.is_exception = is_exception;
        
        if (!options_str.empty()) {
            if (!parse_options(rule, options_str)) continue;
        }
        
        if (line.rfind("||", 0) == 0) {
            std::string rest = line.substr(2);
            size_t slash = rest.find('/');
            if (slash == std::string::npos) {
                // Bare host rule: ||domain or ||domain^ -- matched via the trie.
                std::string domain_part = rest;
                if (!domain_part.empty() &&
                    (domain_part.back() == '^' || domain_part.back() == '|')) {
                    domain_part.pop_back();
                }
                if (domain_part.find('^') != std::string::npos) {
                    // Degenerate mid-separator host (||example^com) -- regex fallback.
                    rule.type = RuleType::Regex;
                    rule.pattern = hostname_anchor_to_regex(domain_part);
                    rule.case_sensitive = false;
                    network_rules.push_back(rule);
                    continue;
                }
                trim(domain_part);
                if (domain_part.empty()) continue;
                rule.type = RuleType::DomainMatch;
                rule.domain = to_lower_copy(domain_part);
                rule.pattern = rule.domain;
                network_rules.push_back(rule);
                continue;
            }
            
            // Path-prefix rule: ||domain/path... -- the request URL (after the
            // scheme) must start with domain/path. Only a bare ||domain stays
            // a DomainMatch; anything with a path is a URL-prefix rule so it
            // never collapses into a whole-domain block.
            std::string dom = rest.substr(0, slash);
            std::string path = rest.substr(slash);
            if (dom.find('^') != std::string::npos ||
                (path.find('^') != std::string::npos &&
                 path.find('^') != path.size() - 1)) {
                // Separator inside the domain or mid-path -- host-anchored regex.
                rule.type = RuleType::Regex;
                rule.pattern = hostname_anchor_to_regex(rest);
                rule.case_sensitive = false;
                network_rules.push_back(rule);
                continue;
            }
            bool trailing_exact = (!path.empty() && path.back() == '|');
            if (trailing_exact) path.pop_back();
            // A trailing '^' stays in the pattern -- the separator-aware matcher
            // consumes it (one separator char or the end of the URL).
            trim(dom);
            if (dom.empty()) continue;
            std::string full = dom + path;
            rule.type = RuleType::PathPrefix;
            rule.domain = to_lower_copy(dom);
            rule.pattern = rule.case_sensitive ? full : to_lower_copy(full);
            rule.trailing_exact = trailing_exact;
            network_rules.push_back(rule);
            continue;
        }
        
        bool anchored_start = false;
        bool anchored_end = false;
        if (line.front() == '|') {
            anchored_start = true;
            line = line.substr(1);
        }
        if (!line.empty() && line.back() == '|') {
            anchored_end = true;
            line = line.substr(0, line.size() - 1);
        }
        
        if (anchored_start && anchored_end) {
            rule.type = RuleType::ExactMatch;
            rule.pattern = rule.case_sensitive ? line : to_lower_copy(line);
            network_rules.push_back(rule);
            continue;
        } else if (anchored_start) {
            rule.type = RuleType::AnchoredStart;
            rule.pattern = rule.case_sensitive ? line : to_lower_copy(line);
            std::string host = line;
            if (host.rfind("http://", 0) == 0) host = host.substr(7);
            else if (host.rfind("https://", 0) == 0) host = host.substr(8);
            
            size_t sep = host.find_first_of("/:?#^");
            if (sep != std::string::npos) {
                host = host.substr(0, sep);
            }
            if (looks_host_like(host)) {
                rule.domain = to_lower_copy(host);
            }
            network_rules.push_back(rule);
            continue;
        } else if (anchored_end) {
            rule.type = RuleType::AnchoredEnd;
            rule.pattern = rule.case_sensitive ? line : to_lower_copy(line);
            network_rules.push_back(rule);
            continue;
        }
        
        // General contains rule
        size_t first_star = line.find('*');
        if (first_star != std::string::npos) {
            std::string clean = line;
            while (!clean.empty() && clean.front() == '*') clean = clean.substr(1);
            while (!clean.empty() && clean.back() == '*') clean = clean.substr(0, clean.size() - 1);
            
            if (clean.find('*') == std::string::npos &&
                clean.find('^') == std::string::npos &&
                !rule.case_sensitive) {
                rule.type = RuleType::Contains;
                rule.pattern = to_lower_copy(clean);
                network_rules.push_back(rule);
            } else {
                // Mid-pattern globs, separators ('^') or $match-case cannot use
                // the char-literal, case-folding Aho-Corasick automaton.
                rule.type = RuleType::Regex;
                rule.pattern = glob_to_regex(rule.case_sensitive ? clean : to_lower_copy(clean));
                network_rules.push_back(rule);
            }
        } else if (line.find('^') != std::string::npos || rule.case_sensitive) {
            // '^' needs separator-aware matching; $match-case needs
            // case-sensitive matching -- both route through the regex path.
            rule.type = RuleType::Regex;
            rule.pattern = glob_to_regex(rule.case_sensitive ? line : to_lower_copy(line));
            network_rules.push_back(rule);
        } else {
            rule.type = RuleType::Contains;
            rule.pattern = to_lower_copy(line);
            network_rules.push_back(rule);
        }
    }
}

std::string RuleParser::glob_to_regex(const std::string& glob) {
    std::string regex;
    for (size_t i = 0; i < glob.size(); ++i) {
        char c = glob[i];
        if (c == '*') {
            regex += ".*";
        } else if (c == '^') {
            // Separator: one char not in [A-Za-z0-9_-.%], or the end of the
            // URL when '^' is the last pattern char.
            regex += (i == glob.size() - 1) ? kSepRegexEnd : kSepRegexMid;
        } else if (c == '.' || c == '+' || c == '?' || c == '$' ||
                   c == '(' || c == ')' || c == '[' || c == ']' || c == '{' ||
                   c == '}' || c == '|' || c == '\\') {
            regex += '\\';
            regex += c;
        } else {
            regex += c;
        }
    }
    return regex;
}

// Converts the body of a "||" rule (host-anchored pattern) into a regex.
// '||' anchors at the start of the hostname (after the scheme) and allows
// any subdomain chain before the anchor host; '^' becomes the separator class.
std::string RuleParser::hostname_anchor_to_regex(const std::string& rest) {
    std::string regex = "^[a-z0-9-]+://(?:[a-z0-9-]+\\.)*";
    regex += glob_to_regex(to_lower_copy(rest));
    return regex;
}

bool RuleParser::looks_host_like(const std::string& host) {
    return host.find('.') != std::string::npos &&
           host.find('*') == std::string::npos &&
           host.find('/') == std::string::npos &&
           host.find(':') == std::string::npos;
}
