import { createUserClient, requireUserId } from "../_shared/supabase.ts";
import {
  errorResponse,
  handleCors,
  handleError,
  jsonResponse,
  readJson,
  RequestError,
  requireRecord,
  requireString,
  requireUuid,
} from "../_shared/http.ts";
import { parseImportText } from "../_shared/import-content.ts";
import {
  downloadImportUrl,
  MAX_IMPORT_BYTES,
  readBoundedResponse,
} from "../_shared/import-url.ts";

const FORMATS = new Set(["csv", "markdown", "quizlet", "remnote"]);
const IMPORT_BUCKET = "import-media";
Deno.serve(async (request) => {
  const cors = handleCors(request);
  if (cors) return cors;
  if (request.method !== "POST") {
    return errorResponse(
      request,
      "Method not allowed",
      405,
      "METHOD_NOT_ALLOWED",
    );
  }

  let remoteStoragePath: string | null = null;
  let jobId: string | null = null;
  let client: ReturnType<typeof createUserClient> | null = null;
  let userId: string | null = null;
  try {
    client = createUserClient(request);
    userId = await requireUserId(client);
    const body = requireRecord(await readJson(request, 1_000_000));
    const deckId = requireUuid(body.deck_id ?? body.deckId, "deck_id");
    const format = requireString(body.format, "format", { maxLength: 16 })
      .toLowerCase();
    if (!FORMATS.has(format)) {
      throw new RequestError(
        "format must be csv, markdown, quizlet or remnote",
        400,
      );
    }

    const suppliedPath = typeof body.storage_path === "string"
      ? body.storage_path.trim()
      : "";
    const suppliedUrl = typeof body.url === "string" ? body.url.trim() : "";
    if (Boolean(suppliedPath) === Boolean(suppliedUrl)) {
      throw new RequestError("Provide exactly one of storage_path or url", 400);
    }
    if (
      suppliedPath &&
      (suppliedPath.length > 500 || !suppliedPath.startsWith(`${userId}/`) ||
        suppliedPath.startsWith("/") || suppliedPath.includes(".."))
    ) {
      throw new RequestError(
        "storage_path must be under the authenticated user's directory",
        400,
      );
    }
    if (suppliedUrl.length > 2048) {
      throw new RequestError("url is too long", 400);
    }

    const { data: deck, error: deckError } = await client.from("decks").select(
      "id",
    ).eq("id", deckId).eq("user_id", userId).maybeSingle();
    if (deckError) throw new Error(deckError.message);
    if (!deck) throw new RequestError("Deck not found", 404);

    let storagePath = suppliedPath;
    if (suppliedUrl) {
      const { bytes } = await downloadImportUrl(suppliedUrl);
      const extension = format === "csv" || format === "quizlet" ? "csv" : "md";
      storagePath = `${userId}/${crypto.randomUUID()}-url-import.${extension}`;
      const contentType = extension === "csv" ? "text/csv" : "text/markdown";
      const uploadBytes = new Uint8Array(bytes.length);
      uploadBytes.set(bytes);
      const { error: uploadError } = await client.storage.from(IMPORT_BUCKET)
        .upload(
          storagePath,
          new Blob([uploadBytes.buffer], { type: contentType }),
          { contentType, upsert: false },
        );
      if (uploadError) throw new Error(uploadError.message);
      remoteStoragePath = storagePath;
    }

    const { data: signed, error: signedError } = await client.storage.from(
      IMPORT_BUCKET,
    ).createSignedUrl(storagePath, 300);
    if (signedError || !signed?.signedUrl) {
      throw new RequestError("Unable to create signed import URL", 404);
    }
    const download = await fetch(signed.signedUrl, {
      signal: AbortSignal.timeout(20_000),
    });
    if (!download.ok) throw new RequestError("Import file unavailable", 404);
    const fileBytes = await readBoundedResponse(download, MAX_IMPORT_BYTES);
    let text: string;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(fileBytes);
    } catch {
      throw new RequestError("Import file must be valid UTF-8 text", 422);
    }
    const notes = parseImportText(text, format);
    if (notes.length === 0) {
      throw new RequestError("Import contains no cards", 422);
    }

    const { data: job, error: jobError } = await client.from("deck_import_jobs")
      .insert({
        user_id: userId,
        deck_id: deckId,
        format,
        storage_path: storagePath,
        status: "processing",
      }).select("id").single();
    if (jobError) throw new Error(jobError.message);
    jobId = job.id;

    const { data: materialized, error: materializeError } = await client.rpc(
      "materialize_import_batch",
      {
        p_job_id: job.id,
        p_user_id: userId,
        p_deck_id: deckId,
        p_notes: notes,
      },
    );
    if (materializeError) throw new Error(materializeError.message);
    return jsonResponse(request, {
      job_id: job.id,
      status: "completed",
      notes_count: materialized?.[0]?.notes_count ?? notes.length,
      cards_count: materialized?.[0]?.cards_count ?? notes.length,
    });
  } catch (error) {
    if (client && userId && jobId) {
      const message = error instanceof Error
        ? error.message.slice(0, 500)
        : "Import failed";
      await client.from("deck_import_jobs").update({
        status: "failed",
        error_message: message,
        updated_at: new Date().toISOString(),
      }).eq("id", jobId).eq("user_id", userId);
    }
    if (client && remoteStoragePath) {
      await client.storage.from(IMPORT_BUCKET).remove([remoteStoragePath]);
    }
    return handleError(error, request);
  }
});
