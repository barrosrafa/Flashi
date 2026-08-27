# Flashi Edge Functions

As funções desta pasta são TypeScript executado no runtime Deno das Supabase Edge Functions. As funções de usuário encaminham o JWT recebido ao Supabase para manter `auth.uid()` e RLS ativos. O único componente com credencial de serviço é `fsrs-optimize-worker`, que executa jobs enfileirados e só aceita JWT cujo claim `role` seja `service_role`.

## Inventário publicado

| Função | Finalidade | JWT | Estado operacional |
|---|---|---|---|
| `sync` | Sincronização incremental com USN e tombstones | usuário | publicada |
| `fsrs-review` | Scheduler FSRS-6 e revisão idempotente | usuário | publicada |
| `embeddings` | Geração/atualização do vetor de uma nota | usuário | publicada |
| `semantic-search` | Embedding de query e busca pela RPC MCP | usuário | publicada; exige provedor no modo semântico |
| `fsrs-optimize` | Enfileirar, executar manualmente e consultar otimização | usuário | publicada |
| `fsrs-optimize-worker` | Processar jobs `queued` em execução agendada | JWT com role `service_role` | publicada; cron é configuração de ambiente |
| `anki-transfer` | Importar/exportar `.apkg` pelo Storage privado | usuário | publicada |
| `ai-ingest` | Validar fonte e criar jobs de ingestão por IA | usuário | publicada; worker de processamento é separado |

Todas as funções devem permanecer com `verify_jwt=true`. O worker periódico possui uma verificação adicional no corpo, portanto um JWT anônimo válido ainda recebe `403`.

## Variáveis e secrets

Configure valores pelo Dashboard ou CLI segura do Supabase. Não versionar `.env`, não inserir chaves em migrations e nunca distribuir `service_role` ao frontend.

```bash
supabase secrets set \
  SUPABASE_URL="https://<project-ref>.supabase.co" \
  SUPABASE_ANON_KEY="<anon-key>" \
  SUPABASE_SERVICE_ROLE_KEY="<service-role-key>" \
  OPENAI_API_KEY="<embedding-provider-key>"
```

`SUPABASE_SERVICE_ROLE_KEY` é usado apenas pelo `fsrs-optimize-worker`. `OPENAI_API_KEY` é usada por `embeddings` e `semantic-search` no modo `semantic`. O modelo padrão é `text-embedding-3-small` e o código exige dimensão 1536; só configure `EMBEDDING_MODEL` se o provedor continuar entregando exatamente essa dimensão. Secrets não aparecem nos responses nem nos logs intencionais.

## Busca semântica

Endpoint: `POST /functions/v1/semantic-search`. O corpo aceita `query` com até 8.000 caracteres, `limit` entre 1 e 100, `mode` como `semantic` ou `lexical` e `request_id` opcional. O modo padrão é `semantic` e chama o endpoint de embeddings externo. O modo `lexical` chama a RPC sem gerar vetor e é a estratégia explícita de disponibilidade degradada.

```json
{
  "query": "como funciona a sincronização offline",
  "limit": 20,
  "mode": "semantic",
  "request_id": "uuid-ou-id-de-rastreio"
}
```

A resposta inclui `user_id`, `mode`, `model`, `dimensions`, `query_hash` e `results`. A RPC `mcp_search_notes()` continua sendo a autoridade para ownership, exclusões lógicas, filtro vetorial e auditoria. Se o secret estiver ausente, o modo semântico retorna `503`; o cliente pode optar por repetir com `mode: "lexical"`, mas a função não mascara automaticamente uma falha do provedor.

## Otimização FSRS

### Solicitação e execução manual

`POST /functions/v1/fsrs-optimize` com `{ "mode": "request" }`, ou sem `mode`, chama `enqueue_fsrs_optimization()` e retorna `202` com `run_id`. A RPC impede uma segunda execução `queued`/`running` para o mesmo usuário quando a regra de elegibilidade não permitir. O cliente acompanha `fsrs_optimization_runs` por meio do próprio endpoint ou de uma consulta autenticada.

Para executar um job específico de forma manual, envie:

```json
{
  "mode": "run",
  "run_id": "00000000-0000-4000-8000-000000000000"
}
```

A execução faz claim por usuário, lê no máximo 25.000 logs FSRS, agrupa revisões por cartão, ordena por horário, chama o WASM `fsrs-browser` e exige exatamente 21 pesos finitos. A conclusão atualiza os pesos em `study_settings` e o status do job na mesma RPC de completion. Erros após o claim passam por `fail_fsrs_optimization_job()` e ficam truncados no banco.

### Worker periódico

`POST /functions/v1/fsrs-optimize-worker` recebe opcionalmente `run_id` e `limit`; o limite é restringido a no máximo cinco jobs por chamada. A função consulta jobs `queued`, usa `claim_fsrs_optimization_job_for_worker()`, lê dados com cliente `service_role`, chama o mesmo helper WASM e conclui ou falha por RPC interna. O corpo rejeita qualquer JWT que não tenha `role=service_role`.

O Supabase recomenda `pg_cron` e `pg_net` para agendar Edge Functions. Depois de guardar `flashi_service_role_jwt` no Vault, o operador pode executar `select private.configure_fsrs_optimizer_cron('<project-url>');`; a função remove o job anterior com o mesmo nome e cria um novo POST de 15 em 15 minutos por padrão. O código não inclui valor de secret nem ativa o cron automaticamente. Não usar polling do frontend.

## Ingestão por IA

Endpoint: `POST /functions/v1/ai-ingest`. A função valida `deck_id`, aceita `source_type` como `pdf_document`, `youtube_url`, `raw_text_block` ou `web_page`, limita a referência a 2.000 caracteres e cria um job `queued` em `ai_ingestion_jobs`. Para uma fonte em Storage, `storage_path` deve começar pelo UUID do usuário; para PDF, o path deve terminar em `.pdf`. O endpoint não baixa, transcreve ou chama LLM: essas operações pertencem ao worker assíncrono descrito em `ai-ingest/WORKER_CONTRACT.md`.

```json
{
  "deck_id": "00000000-0000-4000-8000-000000000000",
  "source_type": "raw_text_block",
  "content": "Texto a ser transformado em notas"
}
```

O worker futuro deve fazer claim atômico, impor o limite de 15 MiB para PDFs, validar a saída estruturada, materializar notas e cartões em uma transação e marcar `completed` ou `failed`. Não enviar credenciais de LLM ao cliente e não registrar conteúdo sensível no job.

## Transferência Anki `.apkg`

O cliente faz upload para o bucket privado `anki-transfers` antes de chamar a função. O path deve começar pelo UUID do usuário e usar `imports/` ou `exports/`:

```text
<user_id>/imports/meu-deck.apkg
<user_id>/exports/<job_id>.apkg
```

A função `anki-transfer` impõe 50 MiB por pacote, 20.000 entradas ZIP, 10.000 notas, 2.000 mídias vinculadas e request JSON de no máximo 2 MiB. Paths absolutos e `../` são rejeitados. O pacote é tratado como dado não confiável; nenhum JavaScript importado é executado.

### Importação

```json
{
  "action": "import",
  "storage_path": "<user_id>/imports/meu-deck.apkg",
  "target_deck_name": "Importado do Anki"
}
```

São aceitos `collection.anki2` e `collection.anki21`. `collection.anki21b` é rejeitado explicitamente. O parser lê modelos, campos, templates, tags e cartões com SQLite WASM. Cloze simples, condicionais básicas, `FrontSide` e referências de campo são renderizados para a representação Flashi. Uma nota sem cartão renderizável usa fallback Basic. Tags são normalizadas e vinculadas aos cartões. Mídia é copiada somente quando o filename aparece em algum campo, com MIME derivado, tamanho e metadata de origem.

A função calcula SHA-256 antes de criar o job. A combinação `(user_id, direction, file_sha256)` é idempotente: uma importação já concluída pode retornar `skipped` sem duplicar conteúdo. A resposta de sucesso inclui `job_id`, `deck_id`, `deck_name`, `total_notes`, `imported_notes`, `imported_cards`, `skipped_notes` e `uploaded_media`.

### Exportação

```json
{
  "action": "export",
  "deck_id": "00000000-0000-4000-8000-000000000000",
  "include_media": true
}
```

A função valida ownership, lê até 10.000 cartões ativos, copia tags e gera o pacote com `fflate` e SQLite WASM. `include_media=false` evita downloads do bucket `card-media`. O resultado é salvo em `<user_id>/exports/<job_id>.apkg`, com SHA-256, tamanho e número de cartões na resposta.

A exportação atual é de conteúdo, não de histórico completo. Ela cria um modelo Basic com `Front` e `Back`, deck derivado, tags e mapa de mídia. Não preserva scheduling, revlogs, estados FSRS/SM-2, múltiplos modelos originais ou CSS avançado. Compatibilidade com `collection.anki21b` e round-trip de um pacote produzido pelo Anki real ainda exigem homologação adicional; não declarar paridade Anki sem esses testes.

## Deploy

Aplique as migrações em `supabase/migrations/` na ordem. `0018_search_optimizer_anki_contracts` cria o bucket `anki-transfers`, os contratos de jobs FSRS e `create_anki_transfer_job()`. `0019_fsrs_scheduler` habilita `pg_cron`/`pg_net` e cria `private.configure_fsrs_optimizer_cron()`, que só agenda o worker depois que o operador guarda `flashi_service_role_jwt` no Vault. `0020_move_pg_net_registration` move o namespace de registro do pg_net para `extensions`; só use a estratégia de drop/recreate quando a fila estiver vazia e não existirem dependências externas, ou solicite o procedimento assistido do Supabase. `0021`–`0024` criam e endurecem a fila AI, oclusão, referências, contratos de gamificação e policies. `0025_user_function_rate_limits` cria o contador atômico por usuário/função usado por `embeddings` e `semantic-search`. Em uma base já sincronizada até `0024`, aplique somente `0025` com `supabase db push` ou pelo fluxo de migração homologado.

Com Supabase CLI:

```bash
supabase functions deploy sync
supabase functions deploy fsrs-review
supabase functions deploy embeddings
supabase functions deploy semantic-search
supabase functions deploy fsrs-optimize
supabase functions deploy fsrs-optimize-worker
supabase functions deploy anki-transfer
supabase functions deploy ai-ingest
```

Antes do deploy, valide import map e tipos:

```bash
deno check --config supabase/functions/deno.json \
  supabase/functions/semantic-search/index.ts \
  supabase/functions/fsrs-optimize/index.ts \
  supabase/functions/fsrs-optimize-worker/index.ts \
  supabase/functions/anki-transfer/index.ts \
  supabase/functions/_shared/anki-apkg.ts \
  supabase/functions/_shared/fsrs-optimizer.ts
```

As dependências estão pinadas em `deno.json`: `@supabase/supabase-js@2.112.4`, `ts-fsrs@5.4.1`, `fflate@0.8.3`, `@sqlite.org/sqlite-wasm@3.53.0-build1` e `fsrs-browser@6.6.0`. Configure `ALLOWED_ORIGINS` como uma lista separada por vírgulas; origens fora da allowlist não recebem `Access-Control-Allow-Origin`. Configure também `OPENAI_API_KEY` e, opcionalmente, `EMBEDDING_MODEL`. As funções retornam erros como `{ error, code, request_id }`; códigos relevantes incluem `VALIDATION_ERROR`, `NOT_FOUND`, `PROVIDER_UNAVAILABLE`, `RATE_LIMITED` e `CARD_STATE_CHANGED`. `embeddings` e `semantic-search` aplicam 30 chamadas por usuário em uma janela fixa de 60 segundos, além do retry limitado do provedor para HTTP 429/5xx.

## Testes

Os testes locais são executados sem secrets:

```bash
deno run --config supabase/functions/deno.json \
  --allow-read --allow-net tests/fsrs_smoke.ts
deno run --config supabase/functions/deno.json \
  --allow-read --allow-net tests/anki_roundtrip.ts
python3 -m unittest -v tests/test_contracts.py
python3 validate_sql.py
python3 validate_readme.py
```

O smoke test FSRS inicializa o WASM no Deno e confirma 21 parâmetros. A função `sync` consulta `limit + 1` registros e devolve no máximo `limit`, evitando uma página final vazia; a regra `cursor_commit_rule` permanece obrigatória. O tipo gerado em `_shared/database.types.ts` é a fonte compartilhada para tabelas e RPCs. O round-trip Anki gera uma coleção SQLite em memória, testa nota, tags, mídia e rejeição de zip-slip. Testes remotos sem usuário autenticado validam apenas o contrato de borda: endpoints de usuário devem responder `401`, e o worker deve responder `403` a um JWT anônimo. Para validar busca semântica, revisão autenticada, jobs e Storage, é necessário um usuário de homologação e os secrets configurados no próprio projeto; não enviar tokens pelo chat.
