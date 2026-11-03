import plistlib,sys
P=sys.argv[1]; Q=sys.argv[2]
a=plistlib.load(open(P,'rb'))['TrailingItemPreferredPositions']; b=plistlib.load(open(Q,'rb'))['TrailingItemPreferredPositions']
print("keys equal:", set(a)==set(b), len(a), len(b))
for k in sorted(a, key=lambda k:a[k]):
    if k in b and a[k]!=b[k]: print(f"{a[k]:6.0f} -> {b[k]:6.0f} ({b[k]-a[k]:+.0f}) {k}")
for k in set(b)-set(a): print("new",k,b[k])
for k in set(a)-set(b): print("gone",k,a[k])
