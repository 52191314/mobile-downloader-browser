# headless_resniffer.dart script-string regexes: match BOTH plain (https://)
# and JSON-escaped (https:\/\/) slashes — each slash optionally preceded by
# one backslash. Correct JS: (?:https?:)?\\?/\\?/  (bytes: \ \ ? / \ \ ? /)
import sys

p = r'D:\02_Projects\aurora_downloader\lib\sniffer\headless_resniffer.dart'
s = open(p, encoding='utf-8').read()

old = '(?:https?:)?\\/\\/'    # bytes: (?:https?:)? \ / \ /  (plain-only)
new = '(?:https?:)?\\\\?/\\\\?/'  # bytes: (?:https?:)? \ \ ? / \ \ ? /  (both)
n = s.count(old)
print('occurrences of plain-only pair:', n)
assert n == 2, 'expected exactly 2'
s = s.replace(old, new)
open(p, 'w', encoding='utf-8', newline='').write(s)
print('fixed both to dual-form')
