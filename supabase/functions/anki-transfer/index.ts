import {
  handleError,
  jsonResponse,
  readJson,
  requireRecord,
  requireString,
  requireUuid,
  RequestError,
  sha256Hex,
} from "../_shared/http.ts";
import { createUserClient, requireUserId } from "../_shared/supabase.ts";
import {
  buildAnkiPackage,
  parseAnkiPackage,
  type ExportCard,
  type ParsedAnkiNote,
} from "../_shared/anki-apkg.ts";

const MAX_PACKAGE_BYTES = 50 * 1024 * 1024;
const MAX_NOTES = 10_000;
const MAX_MEDIA_PER_JOB = 2_000;

function mimeFromFilename(filename: string): { mediaType: "image" | "audio" | "video" | "other"; mimeType: string } {
  const extension = filename.toLowerCase().split(".").pop() ?? "";
  if (["jpg", "jpeg", "png", "gif", "webp", "svg"].includes(extension)) {
    return { mediaType: "image", mimeType: extension === "jpg" ? "image/jpeg" : `image/${extension}` };
  }
  if (["mp3", "wav", "ogg", "m4a", "flac"].includes(extension)) {
    return { mediaType: "audio", mimeType: extension === "mp3" ? "audio/mpeg" : `audio/${extension}` };
  }
  if (["mp4", "webm", "mov", "m4v"].includes(extension)) {
    return { mediaType: "video", mimeType: extension === "mp4" ? "video/mp4" : `video/${extension}` };
  }
  return { mediaType: "other", mimeType: "application/octet-stream" };
}

function safeName(value: string, fallback: string): string {
  const clean = value.replace(/[\\/:*?"<>|\u0000-\u001f]/g, " ").replace(/\s+/g, " ").trim();
  return (clean || fallback).slice(0, 120);
}

async function ensureTargetDeck(
  client: ReturnType<typeof createUserClient>,
  userId: string,
  requestedName: string | undefined,
): Promise<{ id: string; name: string }> {
  const name = safeName(requestedName ?? "", "Imported Anki");
  const { data: existing, error: existingError } = await client
    .from("decks")
    .select("id, name")
    .eq("user_id", userId)
    .eq("name", name)
    .is("deleted_at", null)
    .maybeSingle();
  if (existingError) throw new Error(`target deck query failed: ${existingError.message}`);
  if (existing) return existing as { id: string; name: string };
  const { data, error } = await client
    .from("decks")
    .insert({ user_id: userId, name, visibility: "private" })
    .select("id, name")
    .single();
  if (error || !data) throw new Error(`target deck creation failed: ${error?.message ?? "no data"}`);
  return data as { id: string; name: string };
}

async function ensureTemplate(
  client: ReturnType<typeof createUserClient>,
  userId: string,
  note: ParsedAnkiNote,
): Promise<string> {
  const name = safeName(`Anki model ${note.modelId}`, "Anki model");
  const { data: existing, error: existingError } = await client
    .from("card_templates")
    .select("id")
    .eq("user_id", userId)
    .eq("name", name)
    .maybeSingle();
  if (existingError) throw new Error(`template query failed: ${existingError.message}`);
  if (existing?.id) return String(existing.id);
  const fieldDefinitions = Object.keys(note.fields).map((field, index) => ({ name: field, ord: index }));
  const cardGeneration = note.cards.map((_card, index) => ({
    name: `Card ${index + 1}`,
    front: "{{Front}}",
    back: "{{Back}}",
  }));
  const { data, error } = await client
    .from("card_templates")
    .insert({
      user_id: userId,
      name,
      field_definitions: fieldDefinitions,
      card_generation: cardGeneration,
      is_system: false,
    })
    .select("id")
    .single();
  if (error || !data) throw new Error(`template creation failed: ${error?.message ?? "no data"}`);
  return String(data.id);
}

async function upsertTags(
  client: ReturnType<typeof createUserClient>,
  userId: string,
  names: string[],
): Promise<string[]> {
  const ids: string[] = [];
  for (const rawName of names.slice(0, 100)) {
    const name = safeName(rawName, "tag").slice(0, 60);
    const { data, error } = await client
      .from("tags")
      .upsert({ user_id: userId, name }, { onConflict: "user_id,name" })
      .select("id")
      .single();
    if (error || !data) throw new Error(`tag upsert failed: ${error?.message ?? "no data"}`);
    ids.push(String(data.id));
  }
  return ids;
}

async function importPackage(
  client: ReturnType<typeof createUserClient>,
  userId: string,
  jobId: string,
  bytes: Uint8Array,
  targetDeckName: string | undefined,
): Promise<Record<string, unknown>> {
  const parsed = await parseAnkiPackage(bytes);
  if (parsed.notes.length === 0) throw new RequestError("Anki package contains no importable notes", 422);
  if (parsed.notes.length > MAX_NOTES) throw new RequestError(`Anki package exceeds ${MAX_NOTES} notes`, 413);
  const deck = await ensureTargetDeck(client, userId, targetDeckName);
  let importedNotes = 0;
  let importedCards = 0;
  let skippedNotes = 0;
  let uploadedMedia = 0;

  for (const note of parsed.notes) {
    const { data: existing, error: existingError } = await client
      .from("notes")
      .select("id")
      .eq("user_id", userId)
      .eq("source_format", "anki_apkg")
      .eq("external_id", note.externalId)
      .is("deleted_at", null)
      .maybeSingle();
    if (existingError) throw new Error(`existing note query failed: ${existingError.message}`);
    if (existing) {
      skippedNotes += 1;
      continue;
    }

    const templateId = await ensureTemplate(client, userId, note);
    const contentHash = await sha256Hex(JSON.stringify(note.fields));
    const cardDefinitions = note.cards.map((card) => ({
      card_kind: card.cardKind,
      cloze_ordinal: card.clozeOrdinal === null ? null : String(card.clozeOrdinal),
      front: card.front,
      back: card.back,
    }));
    const { data: created, error: createError } = await client.rpc("mcp_create_note", {
      p_deck_id: deck.id,
      p_fields: note.fields,
      p_template_id: templateId,
      p_card_definitions: cardDefinitions,
      p_source: "mcp",
      p_external_id: note.externalId,
      p_content_hash: contentHash,
      p_request_id: jobId,
    });
    if (createError || !Array.isArray(created) || created.length === 0) {
      throw new Error(`note creation failed: ${createError?.message ?? "no generated IDs"}`);
    }
    const result = created[0] as { note_id?: string; card_ids?: string[] };
    const noteId = String(result.note_id ?? "");
    const cardIds = Array.isArray(result.card_ids) ? result.card_ids.map(String) : [];
    if (!noteId || cardIds.length === 0) throw new Error("note creation returned invalid IDs");

    const { error: noteUpdateError } = await client
      .from("notes")
      .update({ source: "anki_apkg", source_format: "anki_apkg", external_id: note.externalId, content_hash: contentHash })
      .eq("id", noteId)
      .eq("user_id", userId);
    if (noteUpdateError) throw new Error(`note source update failed: ${noteUpdateError.message}`);

    const tagIds = await upsertTags(client, userId, note.tags);
    if (tagIds.length > 0) {
      const tagRows = cardIds.flatMap((cardId) => tagIds.map((tagId) => ({ card_id: cardId, tag_id: tagId })));
      const { error: tagLinkError } = await client.from("card_tags").upsert(tagRows, { onConflict: "card_id,tag_id" });
      if (tagLinkError) throw new Error(`card tag link failed: ${tagLinkError.message}`);
    }

    const matchingMedia = Object.entries(parsed.media).filter(([, filename]) =>
      Object.values(note.fields).some((field) => field.includes(filename))
    );
    if (uploadedMedia + matchingMedia.length > MAX_MEDIA_PER_JOB) {
      throw new RequestError(`Anki package exceeds ${MAX_MEDIA_PER_JOB} linked media files`, 413);
    }
    for (const [archiveKey, filename] of matchingMedia) {
      const mediaBytes = parsed.files[archiveKey];
      if (!mediaBytes) continue;
      const mediaPath = `${userId}/anki/${jobId}/${archiveKey}-${safeName(filename, archiveKey)}`;
      const { error: uploadError } = await client.storage.from("card-media").upload(mediaPath, mediaBytes, {
        contentType: mimeFromFilename(filename).mimeType,
        upsert: true,
      });
      if (uploadError) throw new Error(`media upload failed: ${uploadError.message}`);
      const { mediaType, mimeType } = mimeFromFilename(filename);
      const mediaRows = cardIds.map((cardId) => ({
        card_id: cardId,
        user_id: userId,
        field_name: Object.entries(note.fields).find(([, value]) => value.includes(filename))?.[0] ?? null,
        media_type: mediaType,
        storage_path: mediaPath,
        file_size_bytes: mediaBytes.byteLength,
        mime_type: mimeType,
        metadata: { anki_filename: filename, anki_archive_key: archiveKey },
      }));
      const { error: mediaRowError } = await client.from("card_media").insert(mediaRows);
      if (mediaRowError) throw new Error(`media metadata insert failed: ${mediaRowError.message}`);
      uploadedMedia += 1;
    }
    importedNotes += 1;
    importedCards += cardIds.length;
  }

  return {
    status: "completed",
    deck_id: deck.id,
    deck_name: deck.name,
    total_notes: parsed.notes.length,
    imported_notes: importedNotes,
    imported_cards: importedCards,
    skipped_notes: skippedNotes,
    uploaded_media: uploadedMedia,
  };
}

async function exportDeck(
  client: ReturnType<typeof createUserClient>,
  userId: string,
  jobId: string,
  deckId: string,
  includeMedia: boolean,
): Promise<{ bytes: Uint8Array; totalCards: number; storagePath: string }> {
  const { data: deck, error: deckError } = await client
    .from("decks")
    .select("id, name")
    .eq("id", deckId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .maybeSingle();
  if (deckError) throw new Error(`deck query failed: ${deckError.message}`);
  if (!deck) throw new RequestError("Deck not found", 404);

  const { data: cards, error: cardError } = await client
    .from("cards")
    .select("id, deck_id, fields")
    .eq("deck_id", deckId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .order("created_at", { ascending: true })
    .limit(10_000);
  if (cardError) throw new Error(`card query failed: ${cardError.message}`);
  if (!cards || cards.length === 0) throw new RequestError("Deck contains no exportable cards", 422);

  const cardIds = cards.map((card) => String(card.id));
  const { data: mediaRows, error: mediaError } = includeMedia
    ? await client.from("card_media")
      .select("card_id, field_name, storage_path, metadata")
      .in("card_id", cardIds)
      .eq("user_id", userId)
      .limit(MAX_MEDIA_PER_JOB)
    : { data: [], error: null };
  const { data: tagRows, error: tagError } = await client
    .from("card_tags")
    .select("card_id, tags(name)")
    .in("card_id", cardIds)
    .limit(10_000);
  if (mediaError) throw new Error(`media query failed: ${mediaError.message}`);
  if (tagError) throw new Error(`tag query failed: ${tagError.message}`);

  const tagsByCard = new Map<string, string[]>();
  for (const row of tagRows ?? []) {
    const relation = row.tags as { name?: unknown } | Array<{ name?: unknown }> | null;
    const tag = Array.isArray(relation) ? relation[0] : relation;
    const name = typeof tag?.name === "string" ? tag.name : "";
    if (!name) continue;
    const names = tagsByCard.get(String(row.card_id)) ?? [];
    names.push(name);
    tagsByCard.set(String(row.card_id), names);
  }

  const mediaByCard = new Map<string, Array<{ fieldName: string | null; filename: string; bytes: Uint8Array }>>();
  for (const row of mediaRows ?? []) {
    const metadata = typeof row.metadata === "object" && row.metadata !== null ? row.metadata as Record<string, unknown> : {};
    const filename = safeName(String(metadata.anki_filename ?? String(row.storage_path).split("/").pop() ?? "media"), "media");
    const { data: blob, error: downloadError } = await client.storage.from("card-media").download(String(row.storage_path));
    if (downloadError || !blob) throw new Error(`media download failed: ${downloadError?.message ?? "no data"}`);
    const bytes = new Uint8Array(await blob.arrayBuffer());
    const entries = mediaByCard.get(String(row.card_id)) ?? [];
    entries.push({ fieldName: row.field_name ? String(row.field_name) : null, filename, bytes });
    mediaByCard.set(String(row.card_id), entries);
  }

  const exportCards: ExportCard[] = cards.map((card) => ({
    id: String(card.id),
    deckId: String(card.deck_id),
    deckName: String(deck.name),
    fields: (typeof card.fields === "object" && card.fields !== null) ? card.fields as Record<string, unknown> : {},
    tags: tagsByCard.get(String(card.id)) ?? [],
    media: mediaByCard.get(String(card.id)) ?? [],
  }));
  const bytes = await buildAnkiPackage(exportCards);
  const storagePath = `${userId}/exports/${jobId}.apkg`;
  return { bytes, totalCards: cards.length, storagePath };
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok");
  if (request.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405, { Allow: "POST, OPTIONS" });

  let client: ReturnType<typeof createUserClient> | null = null;
  let jobId: string | null = null;
  let userId = "";
  try {
    client = createUserClient(request);
    userId = await requireUserId(client);
    const body = requireRecord(await readJson(request, 2_000_000));
    const action = requireString(body.action, "action", { maxLength: 8 }).toLowerCase();
    if (action !== "import" && action !== "export") throw new RequestError("action must be import or export", 400);

    if (action === "import") {
      const targetDeckValue = body.target_deck_name ?? body.targetDeckName;
      const targetDeckName = targetDeckValue === undefined
        ? undefined
        : requireString(targetDeckValue, "target_deck_name", { maxLength: 120 });
      const storagePath = requireString(body.storage_path ?? body.storagePath, "storage_path", { maxLength: 500 });
      if (!storagePath.startsWith(`${userId}/imports/`) || !storagePath.toLowerCase().endsWith(".apkg")) {
        throw new RequestError("storage_path must be under the authenticated user's imports directory", 400);
      }
      const { data: blob, error: downloadError } = await client.storage.from("anki-transfers").download(storagePath);
      if (downloadError || !blob) throw new RequestError(`Import file unavailable: ${downloadError?.message ?? "not found"}`, 404);
      const bytes = new Uint8Array(await blob.arrayBuffer());
      if (bytes.byteLength > MAX_PACKAGE_BYTES) throw new RequestError("Anki package is too large", 413);
      const fileHash = await sha256Hex(bytes);
      const { data: createdJob, error: jobError } = await client.rpc("create_anki_transfer_job", {
        p_direction: "import",
        p_storage_path: storagePath,
        p_file_sha256: fileHash,
        p_options: { target_deck_name: targetDeckName ?? null },
      });
      if (jobError) throw new Error(`transfer job creation failed: ${jobError.message}`);
      jobId = String(createdJob);
      const { data: job, error: existingJobError } = await client.from("anki_transfer_jobs").select("id, status").eq("id", jobId).eq("user_id", userId).maybeSingle();
      if (existingJobError) throw new Error(`transfer job query failed: ${existingJobError.message}`);
      if (job?.status === "completed") return jsonResponse({ job_id: jobId, status: "completed", skipped: true, reason: "same package already imported" });
      const { error: runningError } = await client.from("anki_transfer_jobs").update({ status: "running", started_at: new Date().toISOString() }).eq("id", jobId).eq("user_id", userId);
      if (runningError) throw new Error(`transfer job start failed: ${runningError.message}`);
      const result = await importPackage(client, userId, jobId, bytes, targetDeckName);
      const { error: completedError } = await client.from("anki_transfer_jobs").update({ status: "completed", total_notes: result.total_notes, imported_notes: result.imported_notes, imported_cards: result.imported_cards, skipped_notes: result.skipped_notes, completed_at: new Date().toISOString() }).eq("id", jobId).eq("user_id", userId);
      if (completedError) throw new Error(`transfer job completion failed: ${completedError.message}`);
      return jsonResponse({ job_id: jobId, ...result });
    }

    const deckId = requireUuid(body.deck_id ?? body.deckId, "deck_id");
    const exportId = crypto.randomUUID();
    const provisionalPath = `${userId}/exports/${exportId}.apkg`;
    const { data: createdJob, error: jobError } = await client.rpc("create_anki_transfer_job", {
      p_direction: "export",
      p_storage_path: provisionalPath,
      p_options: { include_media: body.include_media !== false },
      p_source_deck_id: deckId,
    });
    if (jobError) throw new Error(`transfer job creation failed: ${jobError.message}`);
    jobId = String(createdJob);
    const { error: runningError } = await client.from("anki_transfer_jobs").update({ status: "running", started_at: new Date().toISOString() }).eq("id", jobId).eq("user_id", userId);
    if (runningError) throw new Error(`transfer job start failed: ${runningError.message}`);
    const result = await exportDeck(client, userId, jobId, deckId, body.include_media !== false);
    if (result.bytes.byteLength > MAX_PACKAGE_BYTES) throw new RequestError("Exported Anki package is too large", 413);
    const { error: uploadError } = await client.storage.from("anki-transfers").upload(result.storagePath, result.bytes, { contentType: "application/zip", upsert: false });
    if (uploadError) throw new Error(`export upload failed: ${uploadError.message}`);
    const fileHash = await sha256Hex(result.bytes);
    const { error: completedError } = await client.from("anki_transfer_jobs").update({ status: "completed", storage_path: result.storagePath, file_sha256: fileHash, total_notes: result.totalCards, imported_notes: result.totalCards, completed_at: new Date().toISOString() }).eq("id", jobId).eq("user_id", userId);
    if (completedError) throw new Error(`transfer job completion failed: ${completedError.message}`);
    return jsonResponse({ job_id: jobId, status: "completed", storage_path: result.storagePath, file_sha256: fileHash, total_cards: result.totalCards, bytes: result.bytes.byteLength });
  } catch (error) {
    if (client && jobId && userId) {
      await client.from("anki_transfer_jobs").update({ status: "failed", error_message: error instanceof Error ? error.message : "Unknown transfer error", completed_at: new Date().toISOString() }).eq("id", jobId).eq("user_id", userId);
    }
    return handleError(error);
  }
});
