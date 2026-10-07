import type { SupabaseClient } from "@supabase/supabase-js";
import { RequestError } from "./http.ts";

export class UserRateLimitError extends RequestError {
  constructor(public readonly retryAfterSec: number) {
    super("Rate limit exceeded", 429, "RATE_LIMITED");
    this.name = "UserRateLimitError";
  }
}

export async function enforceUserRateLimit(client: SupabaseClient, functionName: string, limit = 30, windowSeconds = 60): Promise<void> {
  const { data, error } = await client.rpc("consume_user_rate_limit", {
    p_function_name: functionName,
    p_limit: limit,
    p_window_seconds: windowSeconds,
  });
  if (error) throw new Error(`rate limit check failed: ${error.message}`);
  const result = Array.isArray(data) ? data[0] : data;
  if (!result?.allowed) {
    const retryAfterSec = Number(result?.retry_after_seconds);
    throw new UserRateLimitError(
      Number.isFinite(retryAfterSec) && retryAfterSec > 0
        ? Math.ceil(retryAfterSec)
        : windowSeconds,
    );
  }
}
