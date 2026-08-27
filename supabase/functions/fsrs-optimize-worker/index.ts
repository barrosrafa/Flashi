import { optimizeWeights, MAX_REVIEWS, toFiniteWeights } from "../_shared/fsrs-optimizer.ts";
import { jsonResponse } from "../_shared/http.ts";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

function jwtRole(request: Request): string | null {
  const authorization = request.headers.get("authorization") ?? "";
  const token = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const payloadPart = parts[1];
  if (!payloadPart) return null;
  try {
    const payload = JSON.parse(atob(payloadPart.replaceAll("-", "+").replaceAll("_", "/"))) as { role?: unknown };
    return typeof payload.role === "string" ? payload.role : null;
  } catch {
    return null;
  }
}

function createAdminClient(): SupabaseClient {
  return createClient(
    requiredEnv("SUPABASE_URL"),
    requiredEnv("SUPABASE_SERVICE_ROLE_KEY"),
    { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } },
  );
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok");
  if (request.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);
  if (jwtRole(request) !== "service_role") return jsonResponse({ error: "Forbidden" }, 403);

  try {
    const client = createAdminClient();
    const body = await request.json().catch(() => ({})) as { run_id?: string; limit?: number };
    const requestedLimit = Number(body.limit ?? 1);
    const limit = Number.isInteger(requestedLimit) ? Math.max(1, Math.min(5, requestedLimit)) : 1;

    const { data: queuedRuns, error: queueError } = await client
      .from("fsrs_optimization_runs")
      .select("id, user_id")
      .eq("status", "queued")
      .order("requested_at", { ascending: true })
      .limit(limit);
    if (queueError) throw new Error(`queue query failed: ${queueError.message}`);

    const candidates = body.run_id
      ? (queuedRuns ?? []).filter((run) => run.id === body.run_id)
      : (queuedRuns ?? []);
    const results: Array<Record<string, unknown>> = [];

    for (const run of candidates) {
      const { data: claimed, error: claimError } = await client.rpc(
        "claim_fsrs_optimization_job_for_worker",
        { p_run_id: run.id },
      );
      if (claimError) throw new Error(`claim failed: ${claimError.message}`);
      if (!Array.isArray(claimed) || claimed.length === 0) continue;

      try {
        const [{ data: settings, error: settingsError }, { data: reviewRows, error: reviewError }] = await Promise.all([
          client.from("study_settings").select("fsrs_weights").eq("user_id", run.user_id).maybeSingle(),
          client.from("review_logs").select("card_id, rating, reviewed_at")
            .eq("user_id", run.user_id).eq("algorithm", "fsrs")
            .order("card_id", { ascending: true }).order("reviewed_at", { ascending: true })
            .limit(MAX_REVIEWS),
        ]);
        if (settingsError) throw new Error(`settings query failed: ${settingsError.message}`);
        if (reviewError) throw new Error(`review log query failed: ${reviewError.message}`);
        const rows = (reviewRows ?? []) as Array<{ card_id: string; rating: string; reviewed_at: string }>;
        if (rows.length < 2) throw new Error("At least two FSRS reviews are required for optimization");
        const { weights, cardCount } = await optimizeWeights(rows, toFiniteWeights(settings?.fsrs_weights));
        const { error: completeError } = await client.rpc("complete_fsrs_optimization_job_for_worker", {
          p_run_id: run.id,
          p_user_id: run.user_id,
          p_new_weights: weights,
          p_old_loss: null,
          p_new_loss: null,
        });
        if (completeError) throw new Error(`completion failed: ${completeError.message}`);
        results.push({ run_id: run.id, user_id: run.user_id, status: "completed", review_count: rows.length, card_count: cardCount });
      } catch (error) {
        const message = error instanceof Error ? error.message : "Unknown optimizer error";
        await client.rpc("fail_fsrs_optimization_job_for_worker", {
          p_run_id: run.id,
          p_user_id: run.user_id,
          p_error_message: message,
        });
        results.push({ run_id: run.id, user_id: run.user_id, status: "failed", error: message });
      }
    }

    return jsonResponse({ processed: results.length, results });
  } catch (error) {
    console.error(error);
    return jsonResponse({ error: "Internal server error" }, 500);
  }
});
