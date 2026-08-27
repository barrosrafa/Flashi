import {
  boundedInteger,
  handleError,
  jsonResponse,
  readJson,
  requireRecord,
  RequestError,
} from "../_shared/http.ts";
import { createUserClient, requireUserId } from "../_shared/supabase.ts";

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
    await requireUserId(client);
    const body = requireRecord(await readJson(request));
    const lastUsn = parseUsn(body.last_usn ?? body.lastUsn);
    const limit = boundedInteger(body.limit, "limit", 1, 5000, 500);

    const { data, error } = await client.rpc("get_incremental_sync", {
      p_after_usn: lastUsn,
      p_limit: limit,
    });
    if (error) throw new Error(`incremental sync RPC failed: ${error.message}`);

    const rows = (data ?? []) as Array<{
      entity_type: string;
      entity_key: string;
      usn: number | string;
      is_deleted: boolean;
      payload: Record<string, unknown>;
    }>;
    const nextUsn = maxReturnedUsn(rows, lastUsn);

    return jsonResponse({
      data: rows,
      next_usn: nextUsn,
      has_more: rows.length >= limit,
      // The client must persist the batch before replacing its local cursor.
      cursor_commit_rule: "apply_all_then_commit_next_usn",
    });
  } catch (error) {
    return handleError(error);
  }
});
