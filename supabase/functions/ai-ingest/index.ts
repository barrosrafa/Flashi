import {
  handleError,
  jsonResponse,
  readJson,
  requireRecord,
  requireString,
  requireUuid,
  RequestError,
} from "../_shared/http.ts";
import { createUserClient, requireUserId } from "../_shared/supabase.ts";

const MAX_PDF_BYTES = 15 * 1024 * 1024;
const MAX_REFERENCE_LENGTH = 2_000;
const ALLOWED_SOURCE_TYPES = new Set(["pdf_document", "youtube_url", "raw_text_block", "web_page"]);

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  }});
  if (request.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405, { Allow: "POST, OPTIONS" });

  try {
    const client = createUserClient(request);
    const userId = await requireUserId(client);
    const body = requireRecord(await readJson(request, MAX_PDF_BYTES + 1_000_000));
    const deckId = requireUuid(body.deck_id ?? body.deckId, "deck_id");
    const sourceType = requireString(body.source_type ?? body.sourceType, "source_type", { maxLength: 32 });
    if (!ALLOWED_SOURCE_TYPES.has(sourceType)) throw new RequestError("Unsupported source_type", 400);

    const content = typeof body.content === "string" ? body.content.trim() : undefined;
    const storagePath = typeof body.storage_path === "string" ? body.storage_path.trim() : undefined;
    if (storagePath) {
      if (!storagePath.startsWith(`${userId}/`) || storagePath.startsWith("/") || storagePath.includes("..")) {
        throw new RequestError("storage_path must be under the authenticated user's directory", 400);
      }
      if (sourceType === "pdf_document" && !storagePath.toLowerCase().endsWith(".pdf")) {
        throw new RequestError("PDF storage_path must end with .pdf", 400);
      }
    }
    const sourceReference = storagePath ?? content;
    if (!sourceReference) throw new RequestError("content or storage_path is required", 400);
    if (sourceType === "pdf_document" && content && new TextEncoder().encode(content).byteLength > MAX_PDF_BYTES) {
      throw new RequestError("PDF content exceeds the 15 MB limit", 413);
    }
    if (sourceReference.length > MAX_REFERENCE_LENGTH) throw new RequestError("source reference is too long", 400);

    const { data: deck, error: deckError } = await client
      .from("decks")
      .select("id")
      .eq("id", deckId)
      .eq("user_id", userId)
      .maybeSingle();
    if (deckError) throw new Error(`deck query failed: ${deckError.message}`);
    if (!deck) throw new RequestError("Deck not found or not owned by current user", 404);

    const { data: job, error } = await client.from("ai_ingestion_jobs").insert({
      user_id: userId,
      deck_id: deckId,
      source_type: sourceType,
      source_reference: sourceReference,
      status: "queued",
    }).select("id, status, created_at").single();
    if (error) throw new Error(`job creation failed: ${error.message}`);
    return jsonResponse({ job_id: job.id, status: job.status, created_at: job.created_at });
  } catch (error) {
    return handleError(error);
  }
});
