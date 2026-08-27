import type { SupabaseClient } from "@supabase/supabase-js";
import { RequestError } from "./http.ts";

export async function enforceUserRateLimit(client: SupabaseClient, functionName: string, limit = 30, windowSeconds = 60): Promise<void> {
  const { data, error } = await client.rpc("consume_user_rate_limit", {
    p_function_name: functionName,
    p_limit: limit,
    p_window_seconds: windowSeconds,
  });
  if (error) throw new Error(`rate limit check failed: ${error.message}`);
  const result = Array.isArray(data) ? data[0] : data;
  if (!result?.allowed) throw new RequestError("Rate limit exceeded", 429, "RATE_LIMITED");
}
