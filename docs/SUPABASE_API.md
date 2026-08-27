# API Supabase do Flashi

Este documento descreve o contrato HTTP e `supabase-js` das funcionalidades do Flashi implementadas até a migração `0024_gamification_exams_socratic.sql`. O Supabase expõe funções PostgreSQL pela Data REST API; cada RPC abaixo corresponde a `POST /rest/v1/rpc/<nome-da-função>` e também pode ser chamada com `supabase.rpc()` [1] [2].

> **Regra de segurança:** todas as chamadas de dados e RPCs deste documento exigem um JWT de usuário autenticado. O banco aplica RLS com `auth.uid() = user_id`; portanto, nunca envie um `user_id` de outro usuário e nunca coloque uma chave `service_role` no navegador ou em aplicativo distribuído.

## 1. Configuração do cliente

Use a URL do projeto `https://ykyobzoxoiljyueasdwc.supabase.co` no ambiente do aplicativo. A chave pública/publishable pode ser usada no cliente porque a autorização efetiva é feita pelo JWT e pelas policies RLS. O usuário precisa estar autenticado antes de chamar as RPCs.

```ts
import { createClient } from '@supabase/supabase-js'

export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY,
)

const { data: sessionData } = await supabase.auth.getSession()
if (!sessionData.session) throw new Error('Usuário não autenticado')
```

Para chamadas REST diretas, envie simultaneamente `apikey` e `Authorization: Bearer <access_token>`:

```bash
export SUPABASE_URL="https://ykyobzoxoiljyueasdwc.supabase.co"
export SUPABASE_PUBLISHABLE_KEY="<publishable-key>"
export SUPABASE_ACCESS_TOKEN="<access-token-do-usuario>"

curl -sS "$SUPABASE_URL/rest/v1/rpc/add_user_xp" \
  -X POST \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_user_id":"00000000-0000-0000-0000-000000000000","p_xp_amount":25}'
```

## 2. RPCs públicas autenticadas

| RPC | Método | Objetivo | Retorno |
|---|---|---|---|
| `add_user_xp` | `POST /rest/v1/rpc/add_user_xp` | Soma XP ao perfil do usuário autenticado e recalcula o nível. | Um objeto `user_gamification_profiles`. |
| `get_due_cards_with_exam_schedule` | `POST /rest/v1/rpc/get_due_cards_with_exam_schedule` | Retorna a fila limitada de cartões vencidos e novos, com urgência de prova. | Uma lista de cartões com metadados do exame. |
| `resolve_socratic_remediation` | `POST /rest/v1/rpc/resolve_socratic_remediation` | Conclui uma sessão socrática pertencente ao usuário e reabilita o cartão. | Um objeto `socratic_remediation_sessions`. |
| `get_incremental_sync` | `POST /rest/v1/rpc/get_incremental_sync` | Entrega alterações e tombstones após um cursor USN global. | Uma lista ordenada por `usn`. |

As funções de trigger `check_card_leech_for_socratic()` e `record_sync_grave()` não são endpoints de aplicativo e têm o `EXECUTE` revogado para as roles públicas. Elas são invocadas apenas pelo PostgreSQL.

## 3. Gamificação

### `add_user_xp(p_user_id, p_xp_amount)`

A função cria o perfil caso ele ainda não exista, soma `p_xp_amount` ao `xp_total` e recalcula `level_current` pela fórmula `floor(sqrt(xp_total / 100)) + 1`. O valor deve ser um inteiro não negativo. A função valida que `p_user_id = auth.uid()` antes de escrever.

```ts
const { data, error } = await supabase.rpc('add_user_xp', {
  p_user_id: user.id,
  p_xp_amount: 25,
})
if (error) throw error
console.log(data.xp_total, data.level_current)
```

```bash
curl -sS "$SUPABASE_URL/rest/v1/rpc/add_user_xp" -X POST \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_user_id":"<user-uuid>","p_xp_amount":25}'
```

A tabela `user_gamification_profiles` é privada por usuário. `badges_definition` permite leitura pública para que o catálogo de badges seja exibido; `user_badges` é privado e contém a relação de desbloqueios de cada usuário.

## 4. Agendamento de exames

### Tabela `deck_exams`

Crie o exame diretamente pela Data API em `POST /rest/v1/deck_exams`. O registro precisa usar o `user_id` do usuário autenticado e um `deck_id` pertencente a ele. O campo `priority_level` aceita somente `exam_urgent`, `currently_studying`, `maintaining` e `paused`; `status` aceita `active`, `completed` e `cancelled`.

```ts
const { data: exam, error } = await supabase
  .from('deck_exams')
  .insert({
    user_id: user.id,
    deck_id,
    exam_name: 'Prova de farmacologia',
    target_date: '2026-09-15',
    priority_level: 'exam_urgent',
    status: 'active',
  })
  .select()
  .single()
if (error) throw error
```

A atualização e a exclusão seguem o mesmo recurso, sempre filtrando pelo identificador:

```ts
await supabase.from('deck_exams').update({ status: 'completed' }).eq('id', examId)
await supabase.from('deck_exams').delete().eq('id', examId)
```

### `get_due_cards_with_exam_schedule(p_deck_id, p_limit)`

`p_deck_id` é opcional. Quando informado, a função inclui o deck informado e todos os subdecks recursivos do usuário; quando nulo, consulta todos os decks do usuário. `p_limit` é limitado entre 1 e 5000, com padrão 50. A lógica de cartões novos preserva a cota de `study_settings.new_cards_per_day` menos `daily_statistics.new_cards_studied` do dia atual.

A fila contém cartões vencidos não novos e cartões novos disponíveis. Exames ativos escolhem o exame mais próximo por deck. O fator calculado é `1.0` sem exame ou com mais de 30 dias, `1.2` quando faltam até 30 dias, `1.5` quando faltam até 7 dias e `2.0` quando o exame está vencido ou é hoje. A resposta ordena primeiro as urgências do exame e depois ajusta a data devida pelo fator.

```ts
const { data: queue, error } = await supabase.rpc(
  'get_due_cards_with_exam_schedule',
  { p_deck_id: deckId, p_limit: 40 },
)
if (error) throw error
for (const card of queue ?? []) {
  console.log(card.card_id, card.exam_name, card.days_remaining, card.scheduling_factor)
}
```

Cada item retorna `card_id`, `deck_id`, `fields`, `state`, `due_at`, `interval_days`, `exam_id`, `exam_name`, `target_date`, `days_remaining` e `scheduling_factor`. Campos de exame podem ser nulos quando não existe um exame ativo aplicável ao deck.

## 5. Remediação socrática de leeches

Um cartão torna-se leech quando uma atualização do estado de aprendizagem cruza o limiar `lapses >= 4`. O trigger `BEFORE UPDATE OF lapses` marca `is_suspended = true` e cria, no máximo, uma sessão `queued`/`processing` aberta para o par `(user_id, card_id)`. O enum `card_state` não é alterado: ele continua aceitando apenas `new`, `learning`, `review` e `relearning`.

Leia as sessões do usuário pela tabela `socratic_remediation_sessions`:

```ts
const { data: sessions, error } = await supabase
  .from('socratic_remediation_sessions')
  .select('id, card_id, status, chat_history, created_at, updated_at')
  .in('status', ['queued', 'processing'])
  .order('created_at', { ascending: false })
if (error) throw error
```

### `resolve_socratic_remediation(p_session_id)`

Depois de concluir a conversa no cliente ou no worker de IA, chame a RPC com o identificador da sessão. Ela valida a propriedade pelo JWT, define `status = completed`, remove a suspensão, zera `lapses` e define `due_at = now()` na linha correspondente de `card_learning_state`. A operação é idempotente para sessões já concluídas.

```ts
const { data: resolved, error } = await supabase.rpc(
  'resolve_socratic_remediation',
  { p_session_id: sessionId },
)
if (error) throw error
console.log(resolved.status)
```

```bash
curl -sS "$SUPABASE_URL/rest/v1/rpc/resolve_socratic_remediation" -X POST \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"p_session_id":"<session-uuid>"}'
```

O chat não é gerado automaticamente pelo banco. O aplicativo ou worker deve atualizar `chat_history` usando a policy de ownership e manter mensagens JSONB válidas; a resolução da sessão é a transação final de reabilitação do cartão.

## 6. Sincronização incremental e tombstones

### `get_incremental_sync(p_after_usn, p_limit)`

O cliente deve persistir o último `usn` aplicado. Envie esse valor em `p_after_usn`; para uma sincronização inicial use `0`. `p_limit` tem padrão 500 e teto 5000. O retorno está ordenado por USN ascendente e contém `entity_type`, `entity_key`, `usn`, `is_deleted` e `payload`.

```ts
const { data: changes, error } = await supabase.rpc('get_incremental_sync', {
  p_after_usn: lastUsn,
  p_limit: 500,
})
if (error) throw error
for (const change of changes ?? []) {
  if (change.is_deleted) removeLocally(change.entity_type, change.entity_key)
  else upsertLocally(change.entity_type, change.entity_key, change.payload)
  lastUsn = Math.max(lastUsn, Number(change.usn))
}
```

As novas entidades sincronizáveis são `user_gamification_profile`, `user_badge`, `deck_exam` e `socratic_remediation_session`. Exclusões administrativas e soft deletes são representadas em `graves` como tombstones; o cliente deve aplicar o tombstone antes de avançar o cursor.

## 7. Erros e diagnóstico

| Situação | Causa provável | Ação |
|---|---|---|
| HTTP 401 | JWT ausente, expirado ou inválido. | Renovar a sessão com Supabase Auth e reenviar o Bearer token. |
| HTTP 403 | A role não possui `EXECUTE` ou a operação foi bloqueada pelo RLS. | Usar um usuário autenticado e confirmar ownership. |
| `Only the authenticated owner can add XP` | `p_user_id` não corresponde a `auth.uid()`. | Enviar o UUID do usuário da sessão atual. |
| `Note not found or not owned...` em outras RPCs | Recurso inexistente, apagado ou pertencente a outro usuário. | Consultar o recurso com o JWT atual. |
| Fila vazia | Não há cartões vencidos ou a cota diária de novos cartões foi consumida. | Verificar `card_learning_state`, `study_settings` e `daily_statistics`. |
| Nenhuma sessão socrática | `lapses` não cruzou o limiar ou já existe uma sessão aberta. | Confirmar `lapses >= 4`, `is_suspended` e status da sessão. |

## 8. Implantação e validação

A migração deve ser aplicada depois de `0023_security_definer_cleanup.sql`. No repositório, execute:

```bash
python3 validate_sql.py
python3 -m pytest tests/
git diff --check
```

No ambiente Supabase, confirme a migração `0024_gamification_exams_socratic`, as cinco tabelas novas, as quatro funções novas, o trigger de leech e as policies RLS. Os advisors de segurança podem emitir avisos intencionais para as duas RPCs `SECURITY DEFINER` públicas (`add_user_xp` e `resolve_socratic_remediation`), pois o contrato exige que usuários autenticados as chamem; ambas validam ownership por `auth.uid()` e têm `search_path` fixo.

## Referências

[1]: https://supabase.com/docs/guides/api "Supabase Data REST API"
[2]: https://supabase.com/docs/guides/database/functions "Supabase Database Functions"
[3]: https://supabase.com/docs/reference/javascript/rpc "Supabase JavaScript rpc reference"
[4]: https://supabase.com/docs/guides/database/postgres/row-level-security "Supabase Row Level Security"
