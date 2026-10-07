import { withObservability } from "../_shared/observability.ts";
import {
  handleCors,
  handleError,
  errorResponse,
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
  type AnkiExportModel,
  type AnkiTemplate,
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
  const name = safeName(`Anki ${note.modelName} (${note.modelId})`, "Anki model");
  const { data: existing, error: existingError } = await client
    .from("card_templates")
    .select("id")
    .eq("user_id", userId)
    .eq("name", name)
    .maybeSingle();
  if (existingError) throw new Error(`template query failed: ${existingError.message}`);
  const fieldDefinitions = note.fieldOrder.map((field, ord) => ({ name: field, ord }));
  const cardGeneration = note.templates.map((template) => ({
    name: template.name,
    ordinal: template.ord,
    front: template.qfmt,
    back: template.afmt,
    card_kind: template.cardKind,
    cloze_ordinal: template.clozeOrdinal,
  }));
  let data: { id: string } | null = existing?.id ? { id: String(existing.id) } : null;
  let error: { message: string } | null = null;
  if (data) {
    const updated = await client
      .from("card_templates")
      .update({ field_definitions: fieldDefinitions, card_generation: cardGeneration })
      .eq("id", data.id)
      .eq("user_id", userId)
      .select("id")
      .single();
    data = updated.data as { id: string } | null;
    error = updated.error;
  } else {
    const created = await client
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
    data = created.data as { id: string } | null;
    error = created.error;
  }
  if (error || !data) throw new Error(`template creation failed: ${error?.message ?? "no data"}`);
  const definitions = note.templates.map((template) => ({
    template_id: String(data!.id),
    ordinal: template.ord,
    name: template.name,
    card_kind: template.cardKind,
    front_template: template.qfmt,
    back_template: template.afmt,
    cloze_ordinal: template.clozeOrdinal,
  }));
  if (definitions.length > 0) {
    const { error: definitionError } = await client
      .from("note_card_definitions")
      .upsert(definitions, { onConflict: "template_id,ordinal" });
    if (definitionError) throw new Error(`template definition preservation failed: ${definitionError.message}`);
  }
  return String(data.id);
}

async function upsertTags(
  client: ReturnType<typeof createUserClient>,
  userId: string,
  names: string[],
): Promise<string[]> {
  const ids: string[] = [];
  for (const name of names) {
    if (!name || /\s/.test(name) || name.length > 60) {
      throw new Error(`Anki tag ${name || "(empty)"} cannot be represented by Flashi's tag schema without loss (max 60 characters, no spaces)`);
    }
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
  if (parsed.notes.some((note) => note.cards.length === 0)) {
    throw new RequestError("Anki package contains a note without a real cards row; no synthetic Basic card was created. Re-export the note from Anki with its cards intact.", 422);
  }

  const referencedMedia = new Set<string>();
  for (const note of parsed.notes) {
    for (const [archiveKey, filename] of Object.entries(parsed.media)) {
      if (Object.values(note.fields).some((field) => field.includes(filename))) referencedMedia.add(archiveKey);
    }
  }
  const unreferencedMedia = Object.keys(parsed.media).filter((archiveKey) => !referencedMedia.has(archiveKey));
  if (unreferencedMedia.length > 0) {
    throw new RequestError(`Anki package contains ${unreferencedMedia.length} media file(s) not referenced by any note field; import aborted instead of silently dropping bytes. Attach them to a field in Anki and re-export.`, 422);
  }
  if (referencedMedia.size > MAX_MEDIA_PER_JOB) {
    throw new RequestError(`Anki package exceeds ${MAX_MEDIA_PER_JOB} linked media files`, 413);
  }

  const deck = await ensureTargetDeck(client, userId, targetDeckName);
  const externalIds = parsed.notes.map((note) => note.externalId);
  const { data: existingRows, error: existingRowsError } = await client
    .from("notes")
    .select("external_id")
    .eq("user_id", userId)
    .eq("source_format", "anki_apkg")
    .in("external_id", externalIds)
    .is("deleted_at", null)
    .limit(MAX_NOTES);
  if (existingRowsError) throw new Error(`existing note query failed: ${existingRowsError.message}`);
  const existingIds = new Set((existingRows ?? []).map((row) => String(row.external_id)));

  // A package can contain hundreds of notes. Reusing templates and limiting
  // concurrency avoids thousands of serial round trips while preserving the
  // per-note RPC as the atomic unit of creation.
  const templateCache = new Map<string, Promise<string>>();
  const templateFor = (note: ParsedAnkiNote): Promise<string> => {
    const key = `${note.modelId}:${note.modelName}`;
    let cached = templateCache.get(key);
    if (!cached) {
      cached = ensureTemplate(client, userId, note);
      templateCache.set(key, cached);
    }
    return cached;
  };

  let importedNotes = 0;
  let importedCards = 0;
  let skippedNotes = 0;
  let uploadedMedia = 0;
  let nextIndex = 0;
  const workerCount = Math.min(6, parsed.notes.length);

  const importOne = async (note: ParsedAnkiNote): Promise<void> => {
    if (existingIds.has(note.externalId)) {
      skippedNotes += 1;
      return;
    }
    const templateId = await templateFor(note);
    const contentHash = await sha256Hex(JSON.stringify(note.fields));
    const cardDefinitions = note.cards.map((card) => ({
      card_ordinal: card.ordinal,
      card_kind: card.cardKind,
      cloze_ordinal: card.clozeOrdinal === null ? null : String(card.clozeOrdinal),
      front: card.front,
      back: card.back,
      fields: { ...note.fields, Front: card.front, Back: card.back },
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
    for (const [archiveKey, filename] of matchingMedia) {
      const mediaBytes = parsed.files[archiveKey];
      if (!mediaBytes) continue;
      const sha256 = await sha256Hex(mediaBytes);
      const mediaPath = `${userId}/anki/${jobId}/${archiveKey}-${safeName(filename, archiveKey)}`;
      const { error: uploadError } = await client.storage.from("card-media").upload(mediaPath, mediaBytes, {
        contentType: mimeFromFilename(filename).mimeType,
        upsert: true,
      });
      if (uploadError) throw new Error(`media upload failed: ${uploadError.message}`);
      const { mediaType, mimeType } = mimeFromFilename(filename);
      const fieldNames = Object.entries(note.fields)
        .filter(([, value]) => value.includes(filename))
        .map(([fieldName]) => fieldName);
      const mediaRows = cardIds.flatMap((cardId) => fieldNames.map((fieldName) => ({
        card_id: cardId,
        user_id: userId,
        field_name: fieldName,
        media_type: mediaType,
        storage_path: mediaPath,
        file_size_bytes: mediaBytes.byteLength,
        mime_type: mimeType,
        metadata: { anki_filename: filename, anki_archive_key: archiveKey, anki_sha256: sha256 },
      })));
      const { error: mediaRowError } = await client.from("card_media").insert(mediaRows);
      if (mediaRowError) throw new Error(`media metadata insert failed: ${mediaRowError.message}`);
      uploadedMedia += 1;
    }
    importedNotes += 1;
    importedCards += cardIds.length;
  };

  const worker = async (): Promise<void> => {
    while (true) {
      const index = nextIndex++;
      if (index >= parsed.notes.length) return;
      await importOne(parsed.notes[index]!);
    }
  };
  await Promise.all(Array.from({ length: workerCount }, () => worker()));

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
function objectValue(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

type AnkiNoteRow = { id: string; fields: unknown; template_id: string | null };
type AnkiCardRow = {
  id: string;
  note_id: string;
  note_group_id: string | null;
  deck_id: string;
  fields: unknown;
  card_ordinal: number | null;
  card_kind: string | null;
  cloze_ordinal: number | null;
  template_id: string | null;
};
type AnkiTemplateRow = {
  id: string;
  name: string;
  field_definitions: unknown;
  card_generation: unknown;
};

function modelFromTemplateRow(row: Record<string, unknown> | null, fields: Record<string, unknown>): AnkiExportModel {
  const fieldDefinitions = Array.isArray(row?.field_definitions) ? row.field_definitions : [];
  const modelFields = fieldDefinitions
    .map((value, index) => {
      const definition = objectValue(value);
      const name = typeof definition.name === "string" ? definition.name : "";
      return name ? { name, ord: Number.isInteger(definition.ord) ? Number(definition.ord) : index } : null;
    })
    .filter((value): value is { name: string; ord: number } => value !== null);
  const rawGeneration = Array.isArray(row?.card_generation) ? row.card_generation : [];
  const templates: AnkiTemplate[] = rawGeneration.map((value, index) => {
    const generation = objectValue(value);
    const ord = Number.isInteger(generation.ordinal) ? Number(generation.ordinal) : index;
    const kind = generation.card_kind === "cloze" || generation.card_kind === "reverse" ? generation.card_kind : "basic";
    return {
      name: typeof generation.name === "string" ? generation.name : `Card ${ord + 1}`,
      ord,
      qfmt: typeof generation.front === "string" ? generation.front : "",
      afmt: typeof generation.back === "string" ? generation.back : "",
      cardKind: kind,
      clozeOrdinal: Number.isInteger(generation.cloze_ordinal) ? Number(generation.cloze_ordinal) : null,
    };
  });
  return {
    id: row?.id ? String(row.id) : undefined,
    name: typeof row?.name === "string" ? row.name : "Flashi Basic",
    type: templates.some((template) => template.cardKind === "cloze") ? 1 : 0,
    css: ".card { font-family: arial; font-size: 20px; text-align: center; color: black; background-color: white; }",
    fields: modelFields.length > 0 ? modelFields : Object.keys(fields).map((name, ord) => ({ name, ord })),
    templates,
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

  // Notes define grouping and all original fields. Cards are queried
  // independently so an export never infers cards from a template.
  const { data: notes, error: noteError } = await client
    .from("notes")
    .select("id, fields, template_id")
    .eq("deck_id", deckId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .order("created_at", { ascending: true })
    .limit(10_000);
  if (noteError) throw new Error(`note query failed: ${noteError.message}`);
  if (!notes || notes.length === 0) throw new RequestError("Deck contains no exportable notes", 422);
  const noteRows = notes as unknown as AnkiNoteRow[];
  const noteIds = noteRows.map((note: AnkiNoteRow) => String(note.id));
  const { data: cards, error: cardError } = await client
    .from("cards")
    .select("id, note_id, note_group_id, deck_id, fields, card_ordinal, card_kind, cloze_ordinal, template_id")
    .in("note_id", noteIds)
    .eq("deck_id", deckId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .order("created_at", { ascending: true })
    .limit(10_000);
  if (cardError) throw new Error(`card query failed: ${cardError.message}`);
  if (!cards || cards.length === 0) throw new RequestError("Deck contains notes but no real cards to export", 422);
  const cardRows = cards as unknown as AnkiCardRow[];

  const cardIds = cardRows.map((card: AnkiCardRow) => String(card.id));
  const templateIds = Array.from(new Set(noteRows.map((note: AnkiNoteRow) => note.template_id).filter(Boolean).map(String)));
  const { data: templateRows, error: templateError } = templateIds.length > 0
    ? await client.from("card_templates").select("id, name, field_definitions, card_generation").in("id", templateIds)
    : { data: [], error: null };
  if (templateError) throw new Error(`template query failed: ${templateError.message}`);
  const templateRowList = (templateRows ?? []) as unknown as AnkiTemplateRow[];
  const templatesById = new Map(templateRowList.map((row: AnkiTemplateRow) => [String(row.id), row as unknown as Record<string, unknown>]));

  const { data: mediaRows, error: mediaError } = includeMedia
    ? await client.from("card_media")
      .select("card_id, field_name, storage_path, file_size_bytes, metadata")
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
    if (!names.includes(name)) names.push(name);
    tagsByCard.set(String(row.card_id), names);
  }

  const mediaByCard = new Map<string, Array<{ fieldName: string | null; filename: string; bytes: Uint8Array; sha256: string }>>();
  for (const row of mediaRows ?? []) {
    const metadata = objectValue(row.metadata);
    const filename = String(metadata.anki_filename ?? String(row.storage_path).split("/").pop() ?? "media");
    if (!filename || filename.includes("..")) throw new Error(`Unsafe Anki media filename in metadata: ${filename}`);
    const { data: blob, error: downloadError } = await client.storage.from("card-media").download(String(row.storage_path));
    if (downloadError || !blob) throw new Error(`media download failed: ${downloadError?.message ?? "no data"}`);
    const bytes = new Uint8Array(await blob.arrayBuffer());
    if (row.file_size_bytes !== null && row.file_size_bytes !== undefined && Number(row.file_size_bytes) !== bytes.byteLength) {
      throw new Error(`media byte length mismatch for ${filename}; refusing to export corrupted bytes`);
    }
    const sha256 = await sha256Hex(bytes);
    if (typeof metadata.anki_sha256 === "string" && metadata.anki_sha256 !== sha256) {
      throw new Error(`media SHA-256 mismatch for ${filename}; refusing to export corrupted bytes`);
    }
    const entries = mediaByCard.get(String(row.card_id)) ?? [];
    entries.push({ fieldName: row.field_name ? String(row.field_name) : null, filename, bytes, sha256 });
    mediaByCard.set(String(row.card_id), entries);
  }

  const notesById = new Map(noteRows.map((note: AnkiNoteRow) => [String(note.id), note]));
  const exportCards: ExportCard[] = cardRows.map((card: AnkiCardRow) => {
    const note = notesById.get(String(card.note_id));
    if (!note) throw new Error(`Card ${card.id} has no parent note; refusing to break note grouping`);
    const noteFields = objectValue(note.fields);
    const templateId = note.template_id ? String(note.template_id) : (card.template_id ? String(card.template_id) : "");
    const model = modelFromTemplateRow(templatesById.get(templateId) ?? null, noteFields);
    const ordinal = Number.isInteger(card.card_ordinal) ? Number(card.card_ordinal) : null;
    const template = ordinal === null ? undefined : model.templates?.find((candidate) => candidate.ord === ordinal);
    if (ordinal !== null && model.templates?.length && !template) {
      throw new Error(`Card ${card.id} ordinal ${ordinal} has no saved template metadata; refusing to invent a template`);
    }
    const kind = card.card_kind === "cloze" || card.card_kind === "reverse" ? card.card_kind : "basic";
    return {
      id: String(card.id),
      noteId: String(note.id),
      deckId: String(card.deck_id),
      deckName: String(deck.name),
      fields: objectValue(card.fields),
      noteFields,
      tags: tagsByCard.get(String(card.id)) ?? [],
      cardOrdinal: ordinal ?? undefined,
      cardKind: kind,
      clozeOrdinal: Number.isInteger(card.cloze_ordinal) ? Number(card.cloze_ordinal) : null,
      template,
      model,
      media: mediaByCard.get(String(card.id)) ?? [],
    };
  });
  const bytes = await buildAnkiPackage(exportCards);
  const storagePath = `${userId}/exports/${jobId}.apkg`;
  return { bytes, totalCards: cards.length, storagePath };
}

Deno.serve(withObservability("anki-transfer", async (request) => {
  const corsResponse = handleCors(request);
  if (corsResponse) return corsResponse;
  if (request.method !== "POST") return errorResponse(request, "Method not allowed", 405, "METHOD_NOT_ALLOWED");

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
      if (job?.status === "completed") return jsonResponse(request, { job_id: jobId, status: "completed", skipped: true, reason: "same package already imported" });
      const { error: runningError } = await client.from("anki_transfer_jobs").update({ status: "running", started_at: new Date().toISOString() }).eq("id", jobId).eq("user_id", userId);
      if (runningError) throw new Error(`transfer job start failed: ${runningError.message}`);
      const result = await importPackage(client, userId, jobId, bytes, targetDeckName);
      const { error: completedError } = await client.from("anki_transfer_jobs").update({ status: "completed", total_notes: result.total_notes, imported_notes: result.imported_notes, imported_cards: result.imported_cards, skipped_notes: result.skipped_notes, completed_at: new Date().toISOString() }).eq("id", jobId).eq("user_id", userId);
      if (completedError) throw new Error(`transfer job completion failed: ${completedError.message}`);
      return jsonResponse(request, { job_id: jobId, ...result });
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
    return jsonResponse(request, { job_id: jobId, status: "completed", storage_path: result.storagePath, file_sha256: fileHash, total_cards: result.totalCards, bytes: result.bytes.byteLength });
  } catch (error) {
    if (client && jobId && userId) {
      await client.from("anki_transfer_jobs").update({ status: "failed", error_message: error instanceof Error ? error.message : "Unknown transfer error", completed_at: new Date().toISOString() }).eq("id", jobId).eq("user_id", userId);
    }
    return handleError(error, request, "anki-transfer");
  }
}));
