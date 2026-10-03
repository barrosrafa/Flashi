# Flashi v2 — Snapshot estrutural do schema

A branch `v2` mantém o caminho híbrido definido no SDD:

- **Ambientes novos:** aplicam apenas `supabase/migrations/00_*.sql` até `05_*.sql`, nesta ordem.
- **Ambientes existentes:** mantêm o histórico em `supabase/migrations_archive/` e devem aplicar um dump baseline versionado com `supabase migration repair --status applied` somente depois de `supabase db diff --linked` retornar `No schema changes found`.

## Validação local

```bash
python3 validate_snapshot.py
python3 validate_sql.py
python3 -m unittest tests/test_contracts.py
export PATH="$HOME/.deno/bin:$PATH"
deno check --config supabase/functions/deno.json supabase/tests/rls_multi_user.ts
```

O teste `supabase/tests/rls_multi_user.ts` é executável quando as variáveis `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `TEST_USER_A_EMAIL`, `TEST_USER_A_PASSWORD`, `TEST_USER_B_EMAIL` e `TEST_USER_B_PASSWORD` estão configuradas. Sem credenciais, ele faz skip explícito e não simula um resultado positivo.

## Validação de equivalência em PostgreSQL/Supabase

A aceitação AC1 exige dois bancos reais:

```bash
# Banco A: referência histórica
for f in supabase/migrations_archive/*.sql; do psql "$DB_A" -f "$f"; done

# Banco B: snapshot novo
for f in supabase/migrations/*.sql; do psql "$DB_B" -f "$f"; done

pg_dump --schema-only --no-owner --no-comments "$DB_A" | sort > /tmp/schema_a.sql
pg_dump --schema-only --no-owner --no-comments "$DB_B" | sort > /tmp/schema_b.sql
diff -u /tmp/schema_a.sql /tmp/schema_b.sql
```

A saída deve ser vazia, salvo diferenças cosméticas previamente documentadas. Em produção, o baseline só pode ser reparado depois de o diff ligado estar vazio; o comando de repair não executa o dump nem migra dados.

## Rollback

O tag `pre-refactor-baseline` aponta para o commit anterior à reorganização. Se uma validação falhar, remover a branch `v2` e restaurar `supabase/migrations_archive/*.sql` para `supabase/migrations/` recupera o layout anterior sem alterar Edge Functions ou dados.
