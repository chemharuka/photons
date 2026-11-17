import json,sys,re
from pathlib import Path
catalog=list(json.loads(Path('scripts/localization/catalog.json').read_text()).items())
p=Path('Sources/PhotonsLocalization/Resources/en.json');en=json.loads(p.read_text())
start=int(sys.argv[1]);lines=Path(sys.argv[2]).read_text().splitlines()
for i,line in enumerate(lines,start):
 key,entry=catalog[i]
 assert sorted(re.findall(r'\{\d+\}',entry['zh']))==sorted(re.findall(r'\{\d+\}',line)),(i,entry['zh'],line)
 en[key]=line.replace('\\n','\n')
p.write_text(json.dumps(en,ensure_ascii=False,indent=2)+'\n')
print(start,start+len(lines)-1,'translated',len(en),'/',len(catalog))
