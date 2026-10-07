import { withObservability } from "../_shared/observability.ts";
import {
  getRequestId,
  handleCors,
  handleError,
  jsonResponse,
  readJson,
  requireRecord,
  RequestError,
  sha256Hex,
} from "../_shared/http.ts";
import { createUserClient, requireUserId } from "../_shared/supabase.ts";
import { enforceUserRateLimit } from "../_shared/rate-limit.ts";
import { captureException, capturePostHogEvent, setRequestContext } from "../_shared/observability.ts";

const ALLOWED_FIELDS = new Set(["goal", "target_date", "weekly_minutes"]);

Deno.serve(withObservability("activation", async (request) => {
  const corsResponse = handleCors(request);
  if (corsResponse) return corsResponse;
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const startedAt = performance.now();
  let requestId = getRequestId(request);
  let userId: string | undefined;
  try {
    const idempotencyKey = request.headers.get("idempotency-key")?.trim();
    if (!idempotencyKey) throw new RequestError("Idempotency-Key is required", 400, "IDEMPOTENCY_KEY_REQUIRED");
    if (!/^[A-Za-z0-9._:-]{8,200}$/.test(idempotencyKey)) {
      throw new RequestError("Idempotency-Key is invalid", 400, "INVALID_IDEMPOTENCY_KEY");
    }

    const client = createUserClient(request);
    userId = await requireUserId(client);
    setRequestContext({ functionName: "activation", requestId, userId });
    await Promise.all([
      enforceUserRateLimit(client, "activation-short", 10, 10),
      enforceUserRateLimit(client, "activation-sustained", 60, 60),
    ]);
    const body = requireRecord(await readJson(request), "Activation payload must be an object");
    const unknown = Object.keys(body).filter((key) => !ALLOWED_FIELDS.has(key));
    if (unknown.length) throw new RequestError(`Unknown activation fields: ${unknown.join(", ")}`, 422, "BOPLA_REJECTED");

    const canonical = JSON.stringify({
      goal: body.goal ?? null,
      target_date: body.target_date ?? null,
      weekly_minutes: body.weekly_minutes ?? null,
    });
    const fingerprint = await sha256Hex(`${userId}:${idempotencyKey}:${canonical}`);
    requestId = getRequestId(request);
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
      if (message.includes("AUTH_REQUIRED")) throw new RequestError("Authentication required", 401, "AUTH_REQUIRED");
      if (message.includes("INVALID_IDEMPOTENCY_KEY")) throw new RequestError("Idempotency-Key is invalid", 422, "INVALID_IDEMPOTENCY_KEY");
      if (message.includes("INVALID_FINGERPRINT")) throw new RequestError("Activation fingerprint is invalid", 422, "INVALID_FINGERPRINT");
      if (message.includes("INVALID_GOAL")) throw new RequestError("Goal is invalid", 422, "INVALID_GOAL");
      if (message.includes("INVALID_WEEKLY_MINUTES")) throw new RequestError("Weekly minutes is invalid", 422, "INVALID_WEEKLY_MINUTES");
      if (message.includes("INVALID_TARGET_DATE")) throw new RequestError("Target date is invalid", 422, "INVALID_TARGET_DATE");
      if (message.includes("IDEMPOTENCY_KEY_REUSED")) throw new RequestError("Idempotency-Key was reused with a different payload", 422, "IDEMPOTENCY_KEY_REUSED");
      if (message.includes("IDEMPOTENCY_IN_PROGRESS")) throw new RequestError("Activation is already being processed", 409, "IDEMPOTENCY_IN_PROGRESS");
      throw new Error(message);
    }
    const result = data ?? { status: "ACTIVE", request_id: requestId };
    if (userId) void capturePostHogEvent({ distinctId: userId, event: "activation_backend_completed", properties: { request_id: requestId, status: result.status, duration_ms: Math.round(performance.now() - startedAt), idempotent: true } });
    return jsonResponse(request, result, 200, { "X-Request-Id": requestId });
  } catch (error) {
    captureException(error, { functionName: "activation", requestId, userId, tags: { area: "activation" }, extra: { duration_ms: Math.round(performance.now() - startedAt) } });
    return handleError(error, request, "activation");
  }
}));
