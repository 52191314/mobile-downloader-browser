import zipfile
import sys
import os

script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, script_dir)
from align_elf_16k import parse_elf, load_segments, PAGE

aab_path = os.path.join(script_dir, "..", "build", "app", "outputs", "bundle", "release", "app-release.aab")
if not os.path.exists(aab_path):
    print(f"Error: {aab_path} not found")
    sys.exit(1)

z = zipfile.ZipFile(aab_path)
so_files = [n for n in z.namelist() if n.endswith(".so")]
print(f"Found {len(so_files)} native libraries in app-release.aab:\n")

all_good = True
for name in sorted(so_files):
    data = z.read(name)
    info = parse_elf(data)
    phdrs = info["phdrs"]
    p_off = info["P_OFF"]
    p_vaddr = info["P_VADDR"]
    loads = load_segments(phdrs, p_off)
    
    aligned = True
    for idx in loads:
        ph = phdrs[idx]
        off = ph[p_off]
        vaddr = ph[p_vaddr]
        align = ph[-1] # p_align is last element
        if (vaddr - off) % PAGE != 0 or align < PAGE:
            aligned = False
            break
            
    status = "PASS (16 KB)" if aligned else "4 KB (32-bit/non-aligned)"
    print(f"  [{status:<25}] {name}")
    if not aligned and "arm64-v8a" in name:
        all_good = False

if all_good:
    print("\nSUCCESS: All arm64-v8a native libraries strictly satisfy Google Play 16 KB page-size alignment!")
else:
    print("\nFAIL: One or more arm64-v8a libraries failed 16 KB alignment check.")
