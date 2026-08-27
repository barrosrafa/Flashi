import {
  handleCors,
  boundedInteger,
  handleError,
  errorResponse,
  jsonResponse,
  readJson,
  requireRecord,
  RequestError,
} from "../_shared/http.ts";
import { createUserClient, requireUserId } from "../_shared/supabase.ts";
import type { Database } from "../_shared/database.types.ts";

function parseUsn(value: unknown): string {
  if (value === undefined || value === null) return "0";
  const text = typeof value === "number" ? String(value) : value;
  if (typeof text !== "string" || !/^\d+$/.test(text)) {
    throw new RequestError("last_usn must be a non-negative integer", 400);
  }
  try {
    return BigInt(text).toString();
  } catch {
    throw new RequestError("last_usn is invalid", 400);
  }
}

function maxReturnedUsn(rows: Array<{ usn?: number | string }>, fallback: string): string {
  let max = BigInt(fallback);
  for (const row of rows) {
    if (row.usn === undefined || row.usn === null) continue;
    const value = BigInt(String(row.usn));
    if (value > max) max = value;
  }
  return max.toString();
}

Deno.serve(async (request) => {
  const corsResponse = handleCors(request);
  if (corsResponse) return corsResponse;

  if (request.method !== "POST") {
    return errorResponse(request, "Method not allowed", 405, "METHOD_NOT_ALLOWED");
  }

  try {
    const client = createUserClient(request);
    await requireUserId(client);
    const body = requireRecord(await readJson(request));
    const lastUsn = parseUsn(body.last_usn ?? body.lastUsn);
    const limit = boundedInteger(body.limit, "limit", 1, 5000, 500);

    const { data, error } = await client.rpc("get_incremental_sync", {
      p_after_usn: lastUsn,
      p_limit: limit + 1,
    });
    if (error) throw new Error(`incremental sync RPC failed: ${error.message}`);

    const fetchedRows = (data ?? []) as Database["public"]["Functions"]["get_incremental_sync"]["Returns"];
    const hasMore = fetchedRows.length > limit;
    const rows = fetchedRows.slice(0, limit);
    const nextUsn = maxReturnedUsn(rows, lastUsn);

    return jsonResponse(request, {
      data: rows,
      next_usn: nextUsn,
      has_more: hasMore,
      // The client must persist the batch before replacing its local cursor.
      cursor_commit_rule: "apply_all_then_commit_next_usn",
    });
  } catch (error) {
    return handleError(error, request);
  }
});
