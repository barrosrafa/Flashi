# Contrato do worker `ai-ingest`

A Edge Function `ai-ingest` apenas autentica a solicitação e cria um job `queued` em `public.ai_ingestion_jobs`. O processamento pesado deve ocorrer em um worker assíncrono, acionado por cron, fila ou serviço de execução contínua.

## Entrada e limites

O worker deve ler `id`, `user_id`, `deck_id`, `source_type` e `source_reference`. Os valores aceitos para `source_type` são `pdf_document`, `youtube_url`, `raw_text_block` e `web_page`. O gateway já limita o corpo da solicitação; o worker deve impor novamente o limite de **15 MiB para PDFs** depois de baixar o objeto do Storage, antes de transcrever ou enviar conteúdo ao modelo.

## Fluxo transacional

1. Selecionar um job `queued` por ordem de `created_at` e fazer claim atômico, alterando-o para `processing` somente quando o status ainda for `queued`.
2. Baixar o arquivo privado, obter/transcrever a URL ou normalizar o bloco de texto. O worker não deve aceitar caminhos de Storage pertencentes a outro usuário.
3. Chamar o provedor de LLM com uma saída estruturada. A saída deve conter `notes`, e cada nota deve ter `fields` JSONB não vazio; cartões devem ter `fields` JSONB não vazio, `card_kind` válido (`basic`, `reverse` ou `cloze`) e `card_ordinal` distinto dentro da nota.
4. Materializar o lote em uma única transação. Recomenda-se uma RPC adicional de lote para inserir notas e cartões, sempre preenchendo `cards.user_id`, `cards.note_id`, `cards.card_ordinal` e `cards.fields`, e inicializando `card_learning_state` para cada cartão.
5. Atualizar o job para `completed`, preenchendo `notes_generated_count` e `cards_generated_count`. Em qualquer falha, atualizar para `failed` com uma mensagem sanitizada em `error_message`; não registrar conteúdo sensível nem segredos.

O worker deve usar credenciais de serviço apenas no ambiente do worker e nunca expô-las no cliente. O contrato SQL da migração 0021 já fornece USN, RLS e tombstones para os jobs e para as entidades materializadas. O claim deve possuir timeout/retry para que um job preso em `processing` possa ser recuperado por operação administrativa sem duplicar notas ou cartões.
