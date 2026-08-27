import {
  boundedInteger,
  handleError,
  jsonResponse,
  readJson,
  requireRecord,
  requireString,
  RequestError,
  sha256Hex,
} from "../_shared/http.ts";
import { createUserClient, requireUserId } from "../_shared/supabase.ts";

const MODEL = Deno.env.get("EMBEDDING_MODEL") ?? "text-embedding-3-small";
const DIMENSIONS = 1536;
const MAX_QUERY_CHARS = 8_000;

type SearchMode = "semantic" | "lexical";

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new RequestError(`${name} is not configured`, 503);
  return value;
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
    const query = requireString(body.query, "query", { maxLength: MAX_QUERY_CHARS });
    const limit = boundedInteger(body.limit, "limit", 1, 100, 20);
    const requestedMode = body.mode === undefined
      ? "semantic"
      : requireString(body.mode, "mode", { maxLength: 8 }).toLowerCase();
    if (requestedMode !== "semantic" && requestedMode !== "lexical") {
      throw new RequestError("mode must be semantic or lexical", 400);
    }
    const mode = requestedMode as SearchMode;
    const requestId = body.request_id === undefined
      ? null
      : requireString(body.request_id, "request_id", { maxLength: 120 });

    let queryEmbedding: string | null = null;
    let queryHash: string | null = null;
    if (mode === "semantic") {
      const embedding = await requestEmbedding(query);
      queryEmbedding = `[${embedding.join(",")}]`;
      queryHash = await sha256Hex(query);
    }

    const { data, error } = await client.rpc("mcp_search_notes", {
      p_query: query,
      p_query_embedding: queryEmbedding,
      p_limit: limit,
      p_request_id: requestId,
    });
    if (error) throw new Error(`semantic search failed: ${error.message}`);

    return jsonResponse({
      user_id: userId,
      mode,
      model: mode === "semantic" ? MODEL : null,
      dimensions: mode === "semantic" ? DIMENSIONS : null,
      query_hash: queryHash,
      results: data ?? [],
    });
  } catch (error) {
    return handleError(error);
  }
});
