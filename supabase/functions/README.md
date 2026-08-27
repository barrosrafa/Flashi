# Flashi Edge Functions

As funções desta pasta são TypeScript executado no runtime Deno. Elas mantêm o JWT recebido no request para que o Supabase aplique RLS e derive `auth.uid()` no banco.

## Variáveis de ambiente

Configure os valores no projeto Supabase por meio do mecanismo de secrets. Não crie um arquivo `.env` versionado e não use a chave `service_role` no cliente.

```bash
supabase secrets set \
  SUPABASE_URL="https://<project-ref>.supabase.co" \
  SUPABASE_ANON_KEY="<anon-key>" \
  OPENAI_API_KEY="<embedding-provider-key>"
```

`OPENAI_API_KEY` é utilizado apenas por `embeddings`. O modelo padrão é `text-embedding-3-small`, com dimensão esperada 1536. Para alterar o modelo, defina `EMBEDDING_MODEL` somente se o provedor continuar retornando exatamente 1536 dimensões.

## Implantação

Aplique as migrações `0001`–`0015` primeiro. Depois, na raiz do projeto, execute:

```bash
supabase functions deploy sync
supabase functions deploy fsrs-review
supabase functions deploy embeddings
```

O cliente deve chamar `fsrs-review` com `client_review_id` estável para permitir retries offline sem duplicar logs ou estatísticas. Para sincronização, envie `last_usn` como texto e grave `next_usn` somente após persistir localmente todo o lote recebido.

## Desenvolvimento local

O type-check pode ser executado com Deno:

```bash
deno check --config supabase/functions/deno.json \
  supabase/functions/sync/index.ts \
  supabase/functions/fsrs-review/index.ts \
  supabase/functions/embeddings/index.ts
```

A validação local não substitui os testes de homologação do banco. Em particular, teste RLS com dois usuários, retries concorrentes com o mesmo `client_review_id`, conflitos de USN, dimensões de embedding e paths de Storage fora de `{user_id}/...`.
