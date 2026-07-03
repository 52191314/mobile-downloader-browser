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

static void parse_options(Rule& rule, const std::string& options_str) {
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
        }
    }
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
            parse_options(rule, options_str);
        }
        
        if (line.size() >= 2 && line.front() == '/' && line.back() == '/') {
            rule.type = RuleType::Regex;
            rule.pattern = line.substr(1, line.size() - 2);
            network_rules.push_back(rule);
            continue;
        }
        
        if (line.rfind("||", 0) == 0) {
            rule.type = RuleType::DomainMatch;
            std::string domain_part = line.substr(2);
            size_t sep = domain_part.find_first_of("^/");
            if (sep != std::string::npos) {
                domain_part = domain_part.substr(0, sep);
            }
            trim(domain_part);
            if (domain_part.empty()) continue;
            std::transform(domain_part.begin(), domain_part.end(), domain_part.begin(), [](unsigned char c){ return std::tolower(c); });
            rule.pattern = domain_part;
            rule.domain = domain_part;
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
            rule.pattern = line;
            network_rules.push_back(rule);
            continue;
        } else if (anchored_start) {
            rule.type = RuleType::AnchoredStart;
            rule.pattern = line;
            std::string host = line;
            if (host.rfind("http://", 0) == 0) host = host.substr(7);
            else if (host.rfind("https://", 0) == 0) host = host.substr(8);
            
            size_t sep = host.find_first_of("/:?#");
            if (sep != std::string::npos) {
                host = host.substr(0, sep);
            }
            if (looks_host_like(host)) {
                std::transform(host.begin(), host.end(), host.begin(), [](unsigned char c){ return std::tolower(c); });
                rule.domain = host;
            }
            network_rules.push_back(rule);
            continue;
        } else if (anchored_end) {
            rule.type = RuleType::AnchoredEnd;
            rule.pattern = line;
            network_rules.push_back(rule);
            continue;
        }
        
        // General contains rule
        size_t first_star = line.find('*');
        if (first_star != std::string::npos) {
            std::string clean = line;
            while (!clean.empty() && clean.front() == '*') clean = clean.substr(1);
            while (!clean.empty() && clean.back() == '*') clean = clean.substr(0, clean.size() - 1);
            
            if (clean.find('*') == std::string::npos) {
                rule.type = RuleType::Contains;
                rule.pattern = clean;
                network_rules.push_back(rule);
            } else {
                rule.type = RuleType::Regex;
                rule.pattern = glob_to_regex(clean);
                network_rules.push_back(rule);
            }
        } else {
            rule.type = RuleType::Contains;
            rule.pattern = line;
            network_rules.push_back(rule);
        }
    }
}

std::string RuleParser::glob_to_regex(const std::string& glob) {
    std::string regex;
    for (char c : glob) {
        if (c == '*') {
            regex += ".*";
        } else if (c == '.' || c == '+' || c == '?' || c == '^' || c == '$' ||
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

bool RuleParser::looks_host_like(const std::string& host) {
    return host.find('.') != std::string::npos &&
           host.find('*') == std::string::npos &&
           host.find('/') == std::string::npos &&
           host.find(':') == std::string::npos;
}
