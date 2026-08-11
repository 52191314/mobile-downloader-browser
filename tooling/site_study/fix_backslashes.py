import sys

p = r'D:\02_Projects\aurora_downloader\lib\sniffer\headless_resniffer.dart'
lines = open(p, encoding='utf-8').read().split('\n')
target = 'let u = m[0].replace('
want = "        let u = m[0].replace(/\\\\\\//g, '/');"
for i, ln in enumerate(lines):
    if target in ln:
        lines[i] = want
        print('replaced line', i + 1)
        break
else:
    print('NOT FOUND')
    sys.exit(1)
open(p, 'w', encoding='utf-8', newline='').write('\n'.join(lines))
print('done')
