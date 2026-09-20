import json, glob, os

# Foundry per-file artifacts: out/<Contract>.sol/<Contract>.json
files = glob.glob('out/**/*.json', recursive=True)
print('total out artifacts:', len(files))
targets = [f for f in files if 'EscrowVaultCoverage' in f]
print('EscrowVaultCoverage artifacts:', targets)
if targets:
    d = json.load(open(targets[0]))
    print('keys:', list(d.keys()))
    meta = d.get('metadata', {})
    if isinstance(meta, str):
        try:
            meta = json.loads(meta)
        except Exception as e:
            print('metadata is string not json', str(e)[:50])
    if isinstance(meta, dict):
        ss = meta.get('sources', {})
        print('metadata.sources count:', len(ss) if ss else 0)
        for k in (list(ss.keys())[:5] if ss else []):
            print('  src:', k, 'content len:', len(ss[k].get('content','')))
