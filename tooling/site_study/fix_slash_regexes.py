# Fix the JS script-string regexes in headless_resniffer.dart:
# they must match PLAIN slashes (https:// or //), not require escaped \/ pairs.
# Correct JS: /(?:https?:)?\/\/[^...]/  -> bytes: (?:https?:)? \ / \ /
import sys

p = r'D:\02_Projects\aurora_downloader\lib\sniffer\headless_resniffer.dart'
s = open(p, encoding='utf-8').read()

old = '(?:https?:)?\\\\/\\\\/'  # bytes: (?:https?:)? \ \ / \ \ /
new = '(?:https?:)?\\/\\/'       # bytes: (?:https?:)? \ / \ /
n = s.count(old)
print('occurrences of broken pair:', n)
assert n == 2, 'expected exactly 2 (kHlsDomQueryJs + queryAllMediaUrls)'
s = s.replace(old, new)
open(p, 'w', encoding='utf-8', newline='').write(s)
print('fixed both')
