#!/usr/bin/env python3
"""Wrap Chinese Swift UI strings, preserving interpolation expressions and format specifiers.
Run once for a migration; subsequent runs only collect newly introduced literals.
"""
from pathlib import Path
import re,json,hashlib
catalog_path=Path('scripts/localization/catalog.json')
catalog=json.loads(catalog_path.read_text()) if catalog_path.exists() else {}
skipped=[]
def has_zh(s):return bool(re.search('[\u3400-\u9fff]',s))
def escaped(s):
 return json.dumps(s,ensure_ascii=False)
def argument(a):
 m=re.fullmatch(r'(.+),\s*specifier:\s*("(?:\\.|[^"\\])*")',a,re.S)
 return 'String(format: '+m[2]+', '+m[1]+')' if m else 'String(describing: ('+a+'))'
def scan(text,path,base=0):
 out=[];i=0
 while i<len(text):
  if text.startswith('//',i):
   end=text.find('\n',i);end=len(text) if end<0 else end
   out.append(text[i:end]);i=end;continue
  if text.startswith('/*',i):
   depth=1;end=i+2
   while end<len(text) and depth:
    if text.startswith('/*',end):depth+=1;end+=2
    elif text.startswith('*/',end):depth-=1;end+=2
    else:end+=1
   out.append(text[i:end]);i=end;continue
  if text.startswith('#"',i):
   end=text.find('"#',i+2);end=len(text) if end<0 else end+2
   out.append(text[i:end]);i=end;continue
  if text[i]!='"':
   out.append(text[i]);i+=1;continue
  if text.startswith('"""',i):
   end=text.find('"""',i+3);end=len(text) if end<0 else end+3
   if has_zh(text[i:end]):skipped.append((str(path),text[i:end][:120]))
   out.append(text[i:end]);i=end;continue
  start=i;i+=1;parts=[''];args=[]
  while i<len(text):
   if text[i]=='"':i+=1;break
   if text.startswith('\\(',i):
    j=i+2;depth=1;inquote=False;begin=j
    while j<len(text) and depth:
     if text[j]=='\\':j+=2;continue
     if text[j]=='"':inquote=not inquote
     elif not inquote:
      if text[j]=='(':depth+=1
      elif text[j]==')':depth-=1
     j+=1
    args.append(scan(text[begin:j-1],path,base+begin));parts.append('');i=j;continue
   if text[i]=='\\' and i+1<len(text):parts[-1]+=text[i:i+2];i+=2;continue
   parts[-1]+=text[i];i+=1
  raw=text[start:i]
  if not any(has_zh(p) for p in parts):
   # Still translate nested string values inside interpolations.
   rebuilt='"'+parts[0]
   for arg,part in zip(args,parts[1:]):rebuilt+='\\('+arg+')'+part
   out.append(rebuilt+'"');continue
  line=text[text.rfind('\n',0,start)+1:start]
  if re.search(r'\bcase\s+\w+\s*=\s*$',line) or re.search(r'\bcase\s*$',line):
   skipped.append((str(path),raw));out.append(raw);continue
  template=parts[0]
  for n,part in enumerate(parts[1:]):template+='{'+str(n)+'}'+part
  # Decode Swift's common escapes, without interpreting literal backslashes twice.
  template=re.sub(r'\\([nrt"\\])',lambda m:{'n':'\n','r':'\r','t':'\t','"':'"','\\':'\\'}[m[1]],template)
  key=hashlib.sha256(template.encode()).hexdigest()[:12]
  entry=catalog.setdefault(key,{'zh':template,'files':[]})
  if str(path) not in entry['files']:entry['files'].append(str(path))
  out.append('L10n.tr("'+key+'"'+(' , '+', '.join(argument(a) for a in args) if args else '')+')')
 return ''.join(out)
for folder in ['PhotonsUI','PhotonsCore','PhotonsExport','PhotonsPanorama','PhotonsCatalog','PhotonsExtensions','PhotonsApp','PhotonsJobs','PhotonsPanoramaWorker']:
 for p in Path('Sources',folder).glob('*.swift'):
  if p.name=='UISmokeRunner.swift':continue
  text=p.read_text();new=scan(text,p)
  if text!=new:
   if 'import PhotonsLocalization' not in new:new='import PhotonsLocalization\n'+new
   p.write_text(new)
catalog_path.write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n')
Path('Sources/PhotonsLocalization/Resources/zh-Hans.json').write_text(json.dumps({k:v['zh'] for k,v in catalog.items()},ensure_ascii=False,indent=2)+'\n')
Path('scripts/localization/skipped.json').write_text(json.dumps(skipped,ensure_ascii=False,indent=2)+'\n')
print('Catalog:',len(catalog),'Skipped:',len(skipped))
