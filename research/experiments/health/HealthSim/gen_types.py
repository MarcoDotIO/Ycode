# Generate types.inc (identifier constant names, units, aggregation) from the
# public SDK header HKTypeIdentifiers.h comments. Names and unit strings only.
import re, sys
src = open(sys.argv[1]).read()
out = []
for m in re.finditer(r'HK_EXTERN HKQuantityTypeIdentifier const (HKQuantityTypeIdentifier\w+)[^;]*;\s*//\s*([^,\n]+),\s*([^\n]+)', src):
    name, unit, agg = m.group(1), m.group(2).strip(), m.group(3).strip()
    out.append('Q(%s, @"%s", @"%s")' % (name, unit, agg))
for m in re.finditer(r'HK_EXTERN HKCategoryTypeIdentifier const (HKCategoryTypeIdentifier\w+)[^;]*;\s*//\s*([^\n]+)', src):
    out.append('C(%s, @"%s")' % (m.group(1), m.group(2).strip()))
open(sys.argv[2], 'w').write('\n'.join(out) + '\n')
print(len(out))
