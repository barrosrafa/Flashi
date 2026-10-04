# Observabilidade do backend Flashi

A instrumentação backend é transversal às 12 Supabase Edge Functions: `activation`, `ai-ingest`, `ai-ingest-worker`, `anki-transfer`, `embeddings`, `fsrs-optimize`, `fsrs-optimize-worker`, `fsrs-review`, `import-deck`, `semantic-search`, `sync` e `tts`.

## Contrato

- `withObservability(functionName, handler)` cria/propaga `request_id`, define contexto Sentry e registra `edge_request_completed` ou `edge_request_failed`.
- `handleError(error, request, functionName)` classifica erros como `VALIDATION_ERROR`, `UNAUTHENTICATED`, `FORBIDDEN`, `NOT_FOUND`, `CONFLICT`, `RATE_LIMITED` ou `INTERNAL_ERROR`, preserva `request_id` e envia `edge_request_error` ao PostHog.
- `createObservedFetch` envolve clientes Supabase user/admin e registra chamadas a auth, REST, RPC, Storage e dependências externas por host, método, status e duração.
- Provedores instrumentados: OpenAI embeddings, LLM de ingestão, ElevenLabs TTS, cache TTS e WASM FSRS; payloads e URLs completas não são enviados.
- Sentry recebe exceções não esperadas com `edge_function`, `request_id`, `error_class` e duração; não recebe payload bruto nem PII.
- PostHog recebe somente nome da função, status, outcome, duração, código de erro e request id anônimo.

## Funil backend

`request_started` implícito → validação/auth → operação RPC/Storage/provedor → resposta HTTP → `edge_request_completed` ou `edge_request_error`. A função `activation` também emite `activation_backend_completed` para reconciliar o funil da UI.

## Variáveis

`SENTRY_DSN`, `SENTRY_ENVIRONMENT`, `SENTRY_TRACES_SAMPLE_RATE`, `POSTHOG_PROJECT_TOKEN`, `POSTHOG_HOST` e `POSTHOG_SERVER_ENABLED`.

## Validação de deploy

No ambiente com Deno/CI, executar:

```bash
deno check --config supabase/functions/deno.json \
  supabase/functions/_shared/observability.ts \
  supabase/functions/_shared/http.ts \
  supabase/functions/*/index.ts

deno test --allow-env --allow-net supabase/functions
```

O mapa completo de produto, eventos, erros, funis, dashboards, alertas e privacidade está em `app-flashi/docs/observability-map.md`.
O inventário detalhado de rotas, serviços, tabelas, RPCs, jobs e recomendações operacionais está em `app-flashi/docs/observability-audit.md`.
