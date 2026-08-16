# Flashi — Arquitetura do Banco de Dados (Supabase / PostgreSQL)

## 1. Visão geral

13 tabelas em `public`, todas com RLS habilitado, PKs `uuid`, timestamps
`created_at`/`updated_at` (+ `deleted_at` onde soft delete se aplica).
Todo o cálculo do algoritmo de repetição espaçada (SM-2, FSRS) acontece na
camada de aplicação/edge function — o banco só persiste o resultado de
forma atômica via `record_review()`.

## 2. Decisões de arquitetura (e por que fugi um pouco do brief original)

| Decisão | Por quê |
|---|---|
| Estado do card (`new`/`learning`/...) vive em `card_learning_state`, **não** em `cards` | `cards` é conteúdo (pode ser de um deck público/compartilhado no futuro); o progresso de estudo é sempre por usuário. Colocar o estado direto no card quebraria multiusuário. |
| `cards.fields` é `jsonb` + `card_templates` em vez de colunas fixas `front`/`back`/`explicação` | Suporta Basic, Cloze etc. sem redesenhar o schema depois. Não implementei a separação completa nota→múltiplos cards do Anki real (geraria bem mais complexidade); é uma redução de escopo deliberada. |
| `decks`/`cards`: sem política de `DELETE` no RLS | Usuário final nunca apaga fisicamente — só via `soft_delete_deck()` (UPDATE de `deleted_at`). Hard delete só é possível com `service_role` (job administrativo), preservando histórico de revisões. |
| `deck_collaborators` (nova tabela, não pedida explicitamente) | O enum `deck_visibility` já previa `'shared'`, mas nada modelava *quem* tem acesso. Sem essa tabela o valor `'shared'` seria decorativo. |
| Streak calculado via função (`get_current_streak()`), não armazenado | Uma coluna de streak acumulada tende a dessincronizar silenciosamente. Calcular sob demanda a partir de `daily_statistics` elimina esse risco. |
| `review_logs` imutável (sem UPDATE/DELETE, garantido em RLS **e** trigger) | É o registro de auditoria/histórico de estudo — nunca deve ser alterável, nem por bug de aplicação nem por acesso direto. |
| Sem particionamento de `review_logs` agora | Seria otimização prematura. Fica documentado como próximo passo (partição mensal por `reviewed_at`) quando o volume justificar (dezenas de milhões de linhas). |

## 3. Diagrama ER

```mermaid
erDiagram
    PROFILES ||--o{ DECKS : owns
    PROFILES ||--o{ CARDS : owns
    PROFILES ||--o{ TAGS : owns
    PROFILES ||--|| STUDY_SETTINGS : has
    DECKS ||--o{ DECKS : "parent of"
    DECKS ||--o{ CARDS : contains
    DECKS ||--o{ DECK_COLLABORATORS : "shared with"
    DECKS ||--o{ USER_DECK_SETTINGS : "configured by"
    CARD_TEMPLATES ||--o{ CARDS : "defines shape of"
    CARDS ||--o{ CARD_TAGS : has
    TAGS ||--o{ CARD_TAGS : tags
    CARDS ||--o{ CARD_MEDIA : attaches
    CARDS ||--|| CARD_LEARNING_STATE : "studied via (per user)"
    CARDS ||--o{ REVIEW_LOGS : "reviewed in"
    PROFILES ||--o{ DAILY_STATISTICS : accumulates

    PROFILES {
      uuid id PK
      text display_name
      text language
      text timezone
    }
    DECKS {
      uuid id PK
      uuid user_id FK
      uuid parent_deck_id FK
      text name
      deck_visibility visibility
      timestamptz deleted_at
    }
    DECK_COLLABORATORS {
      uuid deck_id FK
      uuid user_id FK
      collaborator_role role
    }
    CARDS {
      uuid id PK
      uuid user_id FK
      uuid deck_id FK
      uuid template_id FK
      jsonb fields
      timestamptz deleted_at
    }
    CARD_TEMPLATES {
      uuid id PK
      text name
      jsonb field_definitions
    }
    TAGS {
      uuid id PK
      uuid user_id FK
      text name
    }
    CARD_TAGS {
      uuid card_id FK
      uuid tag_id FK
    }
    CARD_MEDIA {
      uuid id PK
      uuid card_id FK
      media_type media_type
      text storage_path
    }
    CARD_LEARNING_STATE {
      uuid id PK
      uuid user_id FK
      uuid card_id FK
      card_state state
      timestamptz due_at
      numeric ease_factor
      numeric stability
    }
    REVIEW_LOGS {
      uuid id PK
      uuid user_id FK
      uuid card_id FK
      review_rating rating
      timestamptz reviewed_at
    }
    STUDY_SETTINGS {
      uuid user_id PK
      srs_algorithm algorithm
      int new_cards_per_day
    }
    USER_DECK_SETTINGS {
      uuid user_id FK
      uuid deck_id FK
      jsonb overrides
    }
    DAILY_STATISTICS {
      uuid user_id FK
      date stat_date PK
      int reviews_count
    }
```

## 4. Consultas essenciais

**Cards pendentes agora** (a consulta mais crítica do sistema, já otimizada
via `idx_learning_due`):
```sql
select * from get_due_cards(p_deck_id := null, p_limit := 30);
```

**Registrar uma revisão** (atômico: `review_logs` + `card_learning_state` +
`daily_statistics` em uma transação):
```sql
select record_review(
  p_card_id           := '...',
  p_rating             := 'good',
  p_time_spent_ms      := 4200,
  p_new_state          := 'review',
  p_new_interval_days  := 6,
  p_new_due_at         := now() + interval '6 days',
  p_new_stability      := 5.8,
  p_new_difficulty     := 4.1,
  p_algorithm          := 'fsrs'
);
```

**Streak atual:**
```sql
select get_current_streak();
```

**Apagar um deck (soft delete, cascateando subdecks e cards):**
```sql
select soft_delete_deck('...');
```

## 5. Storage

Bucket `card-media`, privado. Caminho obrigatório `{user_id}/...` — a
policy de `storage.objects` valida isso via `storage.foldername(name)`.

## 6. Sincronização multi-dispositivo

- Cada linha sincronizável tem `updated_at` (e `deleted_at` para soft
  delete). Cliente guarda `last_synced_at` e busca
  `where updated_at > $last_sync_at or deleted_at > $last_sync_at`.
- Resolução de conflito: **last-write-wins** por `updated_at`. Isso é
  aceitável para conteúdo (decks/cards), mas note a limitação: edições
  simultâneas em dois dispositivos podem perder uma das duas. Para
  `review_logs` isso não é problema — são inserts idempotentes (gere o
  `id` no cliente para deduplicar em reenvios).
- `device_id`/`session_id` em `review_logs` existem só para diagnóstico de
  sincronização, não para lógica de negócio.

## 7. Migrações

Arquivos numerados em `db/migrations/`, pensados para rodar via Supabase
CLI (`supabase db push` ou `supabase migration up`). Todos são
idempotentes: `create table if not exists`, `create index if not exists`,
`drop policy if exists` antes de `create policy`, e blocos `do $$ ... $$`
para enums (Postgres não tem `create type if not exists`).

Ordem de aplicação: `0001` → `0011`, nessa sequência (as dependências de FK
exigem isso).

## 8. Autocrítica (checklist do brief)

- **Normalização:** 3FN nas tabelas de conteúdo; `fields`/`settings`/
  `overrides` em JSONB são exceções deliberadas para extensibilidade, não
  preguiça de modelagem.
- **Concorrência:** `record_review()` usa `select ... for update` na linha
  de `card_learning_state`, evitando corrida entre duas revisões quase
  simultâneas do mesmo card (ex.: retry de rede).
- **RLS:** revisado por tabela (seção 2); pontos de atenção deliberados
  documentados, não escondidos.
- **Consultas lentas em milhões de linhas:** `get_due_cards()` depende de
  `idx_learning_due` (parcial, `where is_suspended = false`) — permanece
  rápida independente do tamanho de `review_logs`, que não participa dessa
  consulta.
- **Índices:** evitei indexar `card_tags` além do necessário (a PK
  composta já cobre a junção mais comum); não há índice redundante.
- **Escala para milhões de revisões:** ver nota de particionamento acima.
- **Múltiplos dispositivos:** coberto (seção 6), com limitação honesta
  documentada (last-write-wins).
- **Evolução do algoritmo:** `srs_algorithm` enum + `algorithm_state`
  JSONB por card + `fsrs_params` JSONB por usuário — nenhuma coluna fica
  amarrada a um único algoritmo.
- **Compartilhamento futuro de decks:** implementado de forma mínima
  (`deck_collaborators`), não apenas prometido no enum.
- **Risco de perda de dados:** `review_logs` imutável; deletes de
  usuário final são sempre soft; FK cascade físico só é alcançável via
  `service_role`.
