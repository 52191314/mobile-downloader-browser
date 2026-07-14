#ifndef RE2_RE2_H_
#define RE2_RE2_H_

#include <memory>
#include <regex>
#include <string>

/// Minimal RE2 stub that replaces the real re2 library with std::regex.
/// Compile with HAVE_RE2=0 (set in CMakeLists.txt.disabled) to use this stub.
class RE2 {
 public:
  explicit RE2(const std::string& pattern) {
    try {
      re_ = std::make_shared<std::regex>(
          pattern, std::regex::ECMAScript | std::regex::optimize);
      ok_ = true;
    } catch (const std::regex_error&) {
      ok_ = false;
    }
  }

  bool ok() const { return ok_; }

  /// Partial match (equivalent to RE2::PartialMatch).
  static bool PartialMatch(const std::string& text, const RE2& re) {
    if (!re.ok_) return false;
    return std::regex_search(text, *re.re_);
  }

 private:
  std::shared_ptr<std::regex> re_;
  bool ok_ = false;
};

#endif  // RE2_RE2_H_
