import { dispatchEdge } from '../_shared/dispatch.ts';
import { getRequestId } from '../_shared/http.ts';
import { withObservability } from "../_shared/observability.ts";
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

Deno.serve(withObservability("fsrs-optimize", async (request) => {
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
    if (mode !== "request" && mode !== "run" && mode !== "dispatch") {
      throw new RequestError("mode must be request or run", 400);
    }

    const launch=(id:string)=>dispatchEdge('fsrs-optimize',{mode:'run',run_id:id},request.headers.get('authorization')??'',getRequestId(request));
    if(mode === 'dispatch') {
      const id=requireUuid(body.run_id,'run_id');
      const {data:run,error}=await client.from('fsrs_optimization_runs').select('id').eq('id',id).eq('user_id',userId).eq('status','queued').maybeSingle();
      if(error||!run)throw new RequestError('Otimização não disponível.',404,'JOB_NOT_FOUND');
      void launch(id); return jsonResponse(request,{run_id:id,status:'queued'},202);
    }
    if (mode === "request") {
      const { data: runId, error } = await client.rpc("enqueue_fsrs_optimization");
      if(error) { if(/requires at least/.test(error.message))throw new RequestError('Ainda não há revisões suficientes para personalizar o agendador. Continue estudando; os parâmetros padrão continuam disponíveis.',422,'OPTIMIZER_NOT_READY'); throw new Error('OPTIMIZER_ENQUEUE_FAILED'); }
      void launch(String(runId));
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
    return handleError(error, request, "fsrs-optimize");
  }
}));
