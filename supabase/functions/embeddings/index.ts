import {
  handleCors,
  handleError,
  errorResponse,
  jsonResponse,
  readJson,
  requireRecord,
  requireUuid,
  RequestError,
  sha256Hex,
} from "../_shared/http.ts";
import { createUserClient, requireUserId } from "../_shared/supabase.ts";
import { enforceUserRateLimit } from "../_shared/rate-limit.ts";

const MAX_TEXT_CHARS = 50_000;

function flattenText(value: unknown, path = ""): string[] {
  if (typeof value === "string") {
    const clean = value.replace(/\s+/g, " ").trim();
    return clean ? [path ? `${path}: ${clean}` : clean] : [];
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return [path ? `${path}: ${String(value)}` : String(value)];
  }
  if (Array.isArray(value)) return value.flatMap((item, index) => flattenText(item, `${path}[${index}]`));
  if (typeof value === "object" && value !== null) {
    return Object.entries(value).flatMap(([key, item]) => flattenText(item, path ? `${path}.${key}` : key));
  }
  return [];
}

import { DIMENSIONS, MODEL, requestEmbedding } from "../_shared/embeddings.ts";

Deno.serve(async (request) => {
  const corsResponse = handleCors(request);
  if (corsResponse) return corsResponse;

  if (request.method !== "POST") {
    return errorResponse(request, "Method not allowed", 405, "METHOD_NOT_ALLOWED");
  }

  try {
    const client = createUserClient(request);
    const userId = await requireUserId(client);
    await enforceUserRateLimit(client, "embeddings", 30, 60);
    const body = requireRecord(await readJson(request));
    const noteId = requireUuid(body.note_id ?? body.noteId, "note_id");

    const { data: note, error: noteError } = await client
      .from("notes")
      .select("id, fields, deleted_at, embedding_model, embedding_content_hash")
      .eq("id", noteId)
      .eq("user_id", userId)
      .maybeSingle();
    if (noteError) throw new Error(`note query failed: ${noteError.message}`);
    if (!note || note.deleted_at !== null) throw new RequestError("Note not found", 404);

    const text = flattenText(note.fields).join("\n").slice(0, MAX_TEXT_CHARS).trim();
    if (!text) throw new RequestError("The note has no textual content", 422);
    const contentHash = await sha256Hex(text);

    if (
      note.embedding_model === MODEL &&
      note.embedding_content_hash === contentHash
    ) {
      return jsonResponse(request, {
        note_id: noteId,
        model: MODEL,
        dimensions: DIMENSIONS,
        content_hash: contentHash,
        skipped: true,
      });
    }

    const embedding = await requestEmbedding(text);
    const vectorLiteral = `[${embedding.join(",")}]`;
    const { error: updateError } = await client
      .from("notes")
      .update({
        embedding: vectorLiteral,
        embedding_model: MODEL,
        embedding_content_hash: contentHash,
        embedding_updated_at: new Date().toISOString(),
      })
      .eq("id", noteId)
      .eq("user_id", userId);
    if (updateError) throw new Error(`embedding persistence failed: ${updateError.message}`);

    return jsonResponse(request, {
      note_id: noteId,
      model: MODEL,
      dimensions: DIMENSIONS,
      content_hash: contentHash,
      skipped: false,
    });
  } catch (error) {
    return handleError(error, request);
  }
});
