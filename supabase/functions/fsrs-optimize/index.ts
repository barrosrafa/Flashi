import {
  handleCors,
  handleError,
  errorResponse,
  jsonResponse,
  readJson,
  requireRecord,
  requireString,
  requireUuid,
  RequestError,
} from "../_shared/http.ts";
import { createUserClient, requireUserId } from "../_shared/supabase.ts";
import { MAX_REVIEWS, optimizeWeights, toFiniteWeights } from "../_shared/fsrs-optimizer.ts";

Deno.serve(async (request) => {
  const corsResponse = handleCors(request);
  if (corsResponse) return corsResponse;
  if (request.method !== "POST") {
    return errorResponse(request, "Method not allowed", 405, "METHOD_NOT_ALLOWED");
  }

  let client: ReturnType<typeof createUserClient> | null = null;
  let userId = "";
  let claimedRunId: string | null = null;
  try {
    client = createUserClient(request);
    userId = await requireUserId(client);
    const body = requireRecord(await readJson(request));
    const mode = body.mode === undefined
      ? "request"
      : requireString(body.mode, "mode", { maxLength: 16 }).toLowerCase();
    if (mode !== "request" && mode !== "run") {
      throw new RequestError("mode must be request or run", 400);
    }

    if (mode === "request") {
      const { data: runId, error } = await client.rpc("enqueue_fsrs_optimization");
      if (error) throw new Error(`optimization enqueue failed: ${error.message}`);
      return jsonResponse(request, { user_id: userId, status: "queued", run_id: runId }, 202);
    }

    const runId = requireUuid(body.run_id ?? body.runId, "run_id");
    const { data: claimed, error: claimError } = await client.rpc("claim_fsrs_optimization_job", {
      p_run_id: runId,
    });
    if (claimError) throw new Error(`optimization claim failed: ${claimError.message}`);
    if (!Array.isArray(claimed) || claimed.length === 0) {
      throw new RequestError("Optimization job is unavailable or already claimed", 409);
    }
    claimedRunId = runId;

    const { data: settings, error: settingsError } = await client
      .from("study_settings")
      .select("fsrs_weights")
      .eq("user_id", userId)
      .maybeSingle();
    if (settingsError) throw new Error(`settings query failed: ${settingsError.message}`);

    const { data: reviewRows, error: reviewError } = await client
      .from("review_logs")
      .select("card_id, rating, reviewed_at")
      .eq("user_id", userId)
      .eq("algorithm", "fsrs")
      .order("card_id", { ascending: true })
      .order("reviewed_at", { ascending: true })
      .limit(MAX_REVIEWS);
    if (reviewError) throw new Error(`review log query failed: ${reviewError.message}`);
    const rows = (reviewRows ?? []) as Array<{ card_id: string; rating: string; reviewed_at: string }>;
    if (rows.length < 2) {
      throw new RequestError("At least two FSRS reviews are required for optimization", 422);
    }

    const oldWeights = toFiniteWeights(settings?.fsrs_weights);
    const { weights: newWeights, cardCount } = await optimizeWeights(rows, oldWeights);
    const { error: completeError } = await client.rpc("complete_fsrs_optimization_job", {
      p_run_id: runId,
      p_new_weights: newWeights,
      p_old_loss: null,
      p_new_loss: null,
    });
    if (completeError) throw new Error(`optimization completion failed: ${completeError.message}`);

    return jsonResponse(request, {
      user_id: userId,
      run_id: runId,
      status: "completed",
      review_count: rows.length,
      card_count: cardCount,
      parameter_count: newWeights.length,
    });
  } catch (error) {
    if (claimedRunId && client) {
      await client.rpc("fail_fsrs_optimization_job", {
        p_run_id: claimedRunId,
        p_error_message: error instanceof Error ? error.message : "Unknown optimizer error",
      });
    }
    return handleError(error, request);
  }
});
