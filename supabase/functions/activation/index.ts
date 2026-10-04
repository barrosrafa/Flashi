import {
  getRequestId,
  handleCors,
  handleError,
  jsonResponse,
  readJson,
  requireRecord,
  requireString,
  RequestError,
  sha256Hex,
} from "../_shared/http.ts";
import { createUserClient, requireUserId } from "../_shared/supabase.ts";

const ALLOWED_FIELDS = new Set(["goal", "target_date", "weekly_minutes"]);

Deno.serve(async (request) => {
  const corsResponse = handleCors(request);
  if (corsResponse) return corsResponse;
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });

  try {
    const idempotencyKey = request.headers.get("idempotency-key")?.trim();
    if (!idempotencyKey) throw new RequestError("Idempotency-Key is required", 400, "IDEMPOTENCY_KEY_REQUIRED");
    if (!/^[A-Za-z0-9._:-]{8,200}$/.test(idempotencyKey)) {
      throw new RequestError("Idempotency-Key is invalid", 400, "IDEMPOTENCY_KEY_INVALID");
    }

    const client = createUserClient(request);
    const userId = await requireUserId(client);
    const [{ data: shortAllowed, error: shortError }, { data: sustainedAllowed, error: sustainedError }] = await Promise.all([
      client.rpc("consume_user_rate_limit", { p_scope: "activation:short", p_limit: 10, p_window_seconds: 10 }),
      client.rpc("consume_user_rate_limit", { p_scope: "activation:sustained", p_limit: 60, p_window_seconds: 60 }),
    ]);
    if (shortError || sustainedError) throw new Error("Rate limit check failed");
    if (shortAllowed === false || sustainedAllowed === false) throw new RequestError("Too many activation attempts", 429, "RATE_LIMITED");
    const body = requireRecord(await readJson(request), "Activation payload must be an object");
    const unknown = Object.keys(body).filter((key) => !ALLOWED_FIELDS.has(key));
    if (unknown.length) throw new RequestError(`Unknown activation fields: ${unknown.join(", ")}`, 422, "BOPLA_REJECTED");

    const canonical = JSON.stringify({
      goal: body.goal ?? null,
      target_date: body.target_date ?? null,
      weekly_minutes: body.weekly_minutes ?? null,
    });
    const fingerprint = await sha256Hex(`${userId}:${idempotencyKey}:${canonical}`);
    const requestId = getRequestId(request);
    const { data, error } = await client.rpc("process_activation", {
      p_idempotency_key: idempotencyKey,
      p_fingerprint: fingerprint,
      p_request_id: requestId,
      p_goal: body.goal ?? null,
      p_target_date: body.target_date ?? null,
      p_weekly_minutes: body.weekly_minutes ?? null,
    });
    if (error) {
      const message = error.message ?? "Activation failed";
      if (message.includes("IDEMPOTENCY_KEY_REUSED")) throw new RequestError("Idempotency-Key was reused with a different payload", 422, "IDEMPOTENCY_KEY_REUSED");
      if (message.includes("IDEMPOTENCY_IN_PROGRESS")) throw new RequestError("Activation is already being processed", 409, "IDEMPOTENCY_IN_PROGRESS");
      throw new Error(message);
    }
    return jsonResponse(request, data ?? { status: "ACTIVE", request_id: requestId }, 200, { "X-Request-Id": requestId });
  } catch (error) {
    return handleError(error, request);
  }
});
