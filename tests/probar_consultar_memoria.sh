#!/usr/bin/env bash
# Verifica el funcionamiento del CLI tools/gateway/consultar_memoria.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/tools/gateway/consultar_memoria.sh"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
export MEMORY_GATEWAY_DB="$TEMP_DIR/gateway.sqlite"
node --input-type=module - "$MEMORY_GATEWAY_DB" <<'JS'
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync(process.argv[2]);
db.exec('CREATE TABLE contracts(method,path,repository,module,revision,document); CREATE TABLE private_memories(id,layer,content,created_at);');
const insert = db.prepare('INSERT INTO contracts VALUES(?,?,?,?,?,?)');
insert.run('POST','/api/posts','posts','posts',1,JSON.stringify({summary:'Crear post'}));
insert.run('GET','/api/posts/{id}/stats','posts','posts',1,JSON.stringify({word_count:12,summary:'stats'}));
db.close();
JS
# Adaptador SQLite real para equipos sin CLI; no utiliza memoria privada del usuario.
if ! command -v sqlite3 >/dev/null; then
  mkdir -p "$TEMP_DIR/bin"
  cat > "$TEMP_DIR/bin/sqlite3" <<'JS'
#!/usr/bin/env node
const { DatabaseSync } = require('node:sqlite');
const args=process.argv.slice(2); let separator='|';
while(args[0]?.startsWith('-')) { const flag=args.shift(); if(flag==='-separator') separator=args.shift(); else if(flag!=='-readonly') process.exit(1); }
const db=new DatabaseSync(args[0],{readOnly:true});
for(const row of db.prepare(args[1]).all()) console.log(Object.values(row).map(v=>v??'').join(separator));
db.close();
JS
  chmod +x "$TEMP_DIR/bin/sqlite3"
  export PATH="$TEMP_DIR/bin:$PATH"
fi

bash -n "$SCRIPT"

"$SCRIPT" >/dev/null
"$SCRIPT" --contratos | grep -F "POST" >/dev/null
"$SCRIPT" --buscar stats | grep -F "stats" >/dev/null
"$SCRIPT" --ver GET "/api/posts/{id}/stats" | grep -F "word_count" >/dev/null
"$SCRIPT" --buscar "'" >/dev/null

echo "✓ Script consultar_memoria.sh verificado correctamente."
