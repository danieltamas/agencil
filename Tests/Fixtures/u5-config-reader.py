import json, sys, time, pathlib, tomllib
config, ready, done, kind = sys.argv[1:]
def read():
    raw = pathlib.Path(config).read_bytes()
    (tomllib.loads(raw.decode()) if kind == 'codex' else json.loads(raw))
read()
pathlib.Path(ready).touch()
deadline = time.monotonic() + 15
count = 0
while not pathlib.Path(done).exists():
    read()
    count += 1
    if time.monotonic() > deadline: raise RuntimeError('writer deadline')
read()
print(count)
