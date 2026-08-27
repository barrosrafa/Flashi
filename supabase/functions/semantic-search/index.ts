import {
  handleCors,
  boundedInteger,
  handleError,
  errorResponse,
  jsonResponse,
  readJson,
  requireRecord,
  requireString,
  RequestError,
  sha256Hex,
} from "../_shared/http.ts";
import { createUserClient, requireUserId } from "../_shared/supabase.ts";
import { enforceUserRateLimit } from "../_shared/rate-limit.ts";

const MAX_QUERY_CHARS = 8_000;

type SearchMode = "semantic" | "lexical";

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
    await enforceUserRateLimit(client, "semantic-search", 30, 60);
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

    return jsonResponse(request, {
      user_id: userId,
      mode,
      model: mode === "semantic" ? MODEL : null,
      dimensions: mode === "semantic" ? DIMENSIONS : null,
      query_hash: queryHash,
      results: data ?? [],
    });
  } catch (error) {
    return handleError(error, request);
  }
});
