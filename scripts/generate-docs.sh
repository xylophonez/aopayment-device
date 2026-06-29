#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

rebar3 edoc

cat > docs/generated.md <<'DOCS'
# Generated Documentation

HTML EDoc output is generated under `doc/` by:

```sh
scripts/generate-docs.sh
```

The checked-in Markdown API and integration notes live in:

- `README.md`
- `docs/api.md`
- `docs/p4-interop.md`
DOCS

echo "generated doc/ and docs/generated.md"

