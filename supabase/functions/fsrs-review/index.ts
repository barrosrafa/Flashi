import {
  fsrs,
  Rating,
  State,
  type CardInput,
  type FSRSParameters,
  type Grade,
  type Steps,
} from "ts-fsrs";
import {
  boundedInteger,
  getRequestId,
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

type ReviewRating = "again" | "hard" | "good" | "easy";
type LearningState = "new" | "learning" | "review" | "relearning";

const ratingMap: Record<ReviewRating, Grade> = {
  again: Rating.Again,
  hard: Rating.Hard,
  good: Rating.Good,
  easy: Rating.Easy,
};

const stateMap: Record<LearningState, State> = {
  new: State.New,
  learning: State.Learning,
  review: State.Review,
  relearning: State.Relearning,
};

const reverseStateMap: Record<number, LearningState> = {
  [State.New]: "new",
  [State.Learning]: "learning",
  [State.Review]: "review",
  [State.Relearning]: "relearning",
};

function asOptionalUuid(value: unknown, field: string): string | null {
  if (value === undefined || value === null || value === "") return null;
  return requireUuid(value, field);
}

function asSteps(value: unknown, fallback: number[]): Steps {
  if (!Array.isArray(value)) return fallback.map((minutes) => `${minutes}m`) as Steps;
  const result = value.map((item) => Number(item));
  if (result.some((item) => !Number.isInteger(item) || item < 1 || item > 24 * 60)) {
    throw new Error("Study step values are invalid");
  }
  return result.map((minutes) => `${minutes}m`) as Steps;
}

function finiteNumber(value: unknown, fallback: number): number {
  const numberValue = Number(value);
  return Number.isFinite(numberValue) ? numberValue : fallback;
}

function toCardInput(row: Record<string, unknown>, now: Date): CardInput {
  const stateName = String(row.state ?? "new") as LearningState;
  if (!(stateName in stateMap)) throw new Error("Stored card state is invalid");

  const lastReview = row.last_reviewed_at ? new Date(String(row.last_reviewed_at)) : null;
  const due = row.due_at ? new Date(String(row.due_at)) : now;
  if (Number.isNaN(due.getTime()) || (lastReview && Number.isNaN(lastReview.getTime()))) {
    throw new Error("Stored card dates are invalid");
  }

  if (stateName !== "new" && !lastReview) {
    throw new Error("Stored card is missing last_reviewed_at");
  }

  const elapsedDays = lastReview
    ? Math.max(0, Math.round((now.getTime() - lastReview.getTime()) / 86_400_000))
    : 0;

  return {
    due,
    stability: finiteNumber(row.stability, 0),
    difficulty: finiteNumber(row.difficulty, 0),
    elapsed_days: elapsedDays,
    scheduled_days: Math.max(0, finiteNumber(row.interval_days, 0)),
    learning_steps: Math.max(0, finiteNumber(row.fsrs_step, 0)),
    reps: Math.max(0, finiteNumber(row.reps, 0)),
    lapses: Math.max(0, finiteNumber(row.lapses, 0)),
    state: stateMap[stateName],
    last_review: lastReview,
  };
}

function buildParameters(settings: Record<string, unknown> | null): Partial<FSRSParameters> {
  const desiredRetention = finiteNumber(settings?.fsrs_desired_retention, 0.9);
  const maximumInterval = finiteNumber(settings?.fsrs_maximum_interval_days, 36500);
  if (desiredRetention <= 0.5 || desiredRetention >= 1) {
    throw new Error("Stored FSRS retention is invalid");
  }
  if (!Number.isInteger(maximumInterval) || maximumInterval < 1 || maximumInterval > 36500) {
    throw new Error("Stored FSRS maximum interval is invalid");
  }

  const configuredWeights = settings?.fsrs_weights;
  const weights = Array.isArray(configuredWeights) && configuredWeights.length === 21
    ? configuredWeights.map(Number)
    : undefined;
  if (weights?.some((weight) => !Number.isFinite(weight))) {
    throw new Error("Stored FSRS weights are invalid");
  }

  return {
    request_retention: desiredRetention,
    maximum_interval: maximumInterval,
    ...(weights ? { w: weights } : {}),
    enable_fuzz: false,
    enable_short_term: true,
    learning_steps: asSteps(settings?.learning_steps_minutes, [1, 10]),
    relearning_steps: asSteps(settings?.relearning_steps_minutes, [10]),
  };
}

Deno.serve(async (request) => {
  const corsResponse = handleCors(request);
  if (corsResponse) return corsResponse;

  if (request.method !== "POST") {
    return errorResponse(request, "Method not allowed", 405, "METHOD_NOT_ALLOWED");
  }

  try {
    const client = createUserClient(request);
    const userId = await requireUserId(client);
    const body = requireRecord(await readJson(request));
    const cardId = requireUuid(body.card_id ?? body.cardId, "card_id");
    const clientReviewId = requireUuid(
      body.client_review_id ?? body.clientReviewId,
      "client_review_id",
    );
    const ratingName = requireString(body.rating, "rating", { maxLength: 5 }).toLowerCase() as ReviewRating;
    if (!(ratingName in ratingMap)) {
      throw new RequestError("rating must be again, hard, good, or easy", 400);
    }

    const timeSpentMs = boundedInteger(
      body.time_spent_ms ?? body.timeSpentMs,
      "time_spent_ms",
      0,
      86_400_000,
      0,
    );
    const deviceId = body.device_id === undefined || body.device_id === null
      ? null
      : requireString(body.device_id, "device_id", { maxLength: 200 });
    const sessionId = asOptionalUuid(body.session_id ?? body.sessionId, "session_id");
    const now = new Date();

    const [{ data: stateRow, error: stateError }, { data: settingsRow, error: settingsError }] =
      await Promise.all([
        client.from("card_learning_state")
          .select("usn, due_at, stability, difficulty, interval_days, reps, lapses, state, last_reviewed_at, fsrs_step")
          .eq("user_id", userId)
          .eq("card_id", cardId)
          .single(),
        client.from("study_settings")
          .select("fsrs_desired_retention, fsrs_maximum_interval_days, fsrs_weights, learning_steps_minutes, relearning_steps_minutes")
          .eq("user_id", userId)
          .maybeSingle(),
      ]);
    if (stateError || !stateRow) throw new RequestError("Learning state not found", 404);
    if (settingsError) throw new Error(`study settings query failed: ${settingsError.message}`);

    const parameters = buildParameters((settingsRow ?? null) as Record<string, unknown> | null);
    const scheduler = fsrs(parameters);
    const currentCard = toCardInput(stateRow as Record<string, unknown>, now);
    const currentRetrievability = scheduler.get_retrievability(currentCard, now, false);
    const result = scheduler.next(currentCard, now, ratingMap[ratingName]);
    const nextCard = result.card;
    const nextState = reverseStateMap[nextCard.state];
    if (!nextState) throw new Error("FSRS returned an unknown state");

    const algorithmState = {
      fsrs_version: "fsrs-6",
      parameter_version: 1,
      request_retention: parameters.request_retention ?? 0.9,
      maximum_interval: parameters.maximum_interval ?? 36500,
      rating: ratingName,
      review_time: now.toISOString(),
    };

    const { data: reviewId, error: persistError } = await client.rpc(
      "record_review_fsrs6_idempotent",
      {
        p_card_id: cardId,
        p_rating: ratingName,
        p_time_spent_ms: timeSpentMs,
        p_new_state: nextState,
        p_new_interval_days: Math.max(0, nextCard.scheduled_days),
        p_new_due_at: nextCard.due.toISOString(),
        p_fsrs_state: nextCard.state,
        p_fsrs_step: Math.max(0, Math.trunc(nextCard.learning_steps)),
        p_fsrs_retrievability: currentRetrievability,
        p_elapsed_days: Math.max(0, Math.trunc(result.log.elapsed_days)),
        p_scheduled_days: Math.max(0, Math.trunc(result.log.scheduled_days)),
        p_new_stability: nextCard.stability,
        p_new_difficulty: nextCard.difficulty,
        p_parameter_version: 1,
        p_algorithm_state: algorithmState,
        p_device_id: deviceId,
        p_session_id: sessionId,
        p_client_review_id: clientReviewId,
        p_expected_usn: String(stateRow.usn),
      },
    );
    if (persistError) {
      if (persistError.message.includes("CARD_STATE_CHANGED")) {
        return jsonResponse(request, { error: "Card changed on server; refresh and retry", code: "CARD_STATE_CHANGED", request_id: getRequestId(request) }, 409);
      }
      throw new Error(`FSRS persistence failed: ${persistError.message}`);
    }

    return jsonResponse(request, {
      review_id: reviewId,
      client_review_id: clientReviewId,
      card_id: cardId,
      state: nextState,
      due_at: nextCard.due.toISOString(),
      interval_days: nextCard.scheduled_days,
      stability: nextCard.stability,
      difficulty: nextCard.difficulty,
    });
  } catch (error) {
    return handleError(error, request);
  }
});
