import {
  handleError,
  jsonResponse,
  readJson,
  requireRecord,
  requireUuid,
  RequestError,
  sha256Hex,
} from "../_shared/http.ts";
import { createUserClient, requireUserId } from "../_shared/supabase.ts";

const MODEL = Deno.env.get("EMBEDDING_MODEL") ?? "text-embedding-3-small";
const DIMENSIONS = 1536;
const MAX_TEXT_CHARS = 50_000;

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function flattenText(value: unknown, path = ""): string[] {
  if (typeof value === "string") {
    const clean = value.replace(/\s+/g, " ").trim();
    return clean ? [path ? `${path}: ${clean}` : clean] : [];
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return [path ? `${path}: ${String(value)}` : String(value)];
  }
  if (Array.isArray(value)) {
    return value.flatMap((item, index) => flattenText(item, `${path}[${index}]`));
  }
  if (typeof value === "object" && value !== null) {
    return Object.entries(value).flatMap(([key, item]) =>
      flattenText(item, path ? `${path}.${key}` : key)
    );
  }
  return [];
}

async function requestEmbedding(input: string): Promise<number[]> {
  const response = await fetch("https://api.openai.com/v1/embeddings", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${requiredEnv("OPENAI_API_KEY")}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: MODEL,
      input,
      encoding_format: "float",
    }),
    signal: AbortSignal.timeout(30_000),
  });

  if (!response.ok) {
    // Keep provider details out of the client response and project logs.
    throw new Error(`Embedding provider returned HTTP ${response.status}`);
  }

  const payload = await response.json() as {
    data?: Array<{ embedding?: unknown }>;
  };
  const embedding = payload.data?.[0]?.embedding;
  if (!Array.isArray(embedding) || embedding.length !== DIMENSIONS) {
    throw new Error(`Embedding dimension mismatch for ${MODEL}`);
  }
  const numericEmbedding = embedding.map(Number);
  if (numericEmbedding.some((value) => !Number.isFinite(value))) {
    throw new Error("Embedding contains non-finite values");
  }
  return numericEmbedding;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
      },
    });
  }

  if (request.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405, { Allow: "POST, OPTIONS" });
  }

  try {
    const client = createUserClient(request);
    const userId = await requireUserId(client);
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
      return jsonResponse({
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

    return jsonResponse({
      note_id: noteId,
      model: MODEL,
      dimensions: DIMENSIONS,
      content_hash: contentHash,
      skipped: false,
    });
  } catch (error) {
    return handleError(error);
  }
});
