export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function jsonResponse(
  body: unknown,
  status = 200,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
      ...headers,
    },
  });
}

export async function readJson(request: Request, maxBytes = 1_000_000): Promise<unknown> {
  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > maxBytes) {
    throw new RequestError("Request body is too large", 413);
  }

  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > maxBytes) {
    throw new RequestError("Request body is too large", 413);
  }
  if (!text.trim()) return {};

  try {
    return JSON.parse(text);
  } catch {
    throw new RequestError("Request body must be valid JSON", 400);
  }
}

export function requireRecord(value: unknown, message = "Request body must be an object"):
  Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new RequestError(message, 400);
  }
  return value as Record<string, unknown>;
}

export function requireString(
  value: unknown,
  field: string,
  options: { maxLength?: number; allowEmpty?: boolean } = {},
): string {
  if (typeof value !== "string") {
    throw new RequestError(`${field} must be a string`, 400);
  }
  const result = value.trim();
  if (!options.allowEmpty && result.length === 0) {
    throw new RequestError(`${field} cannot be empty`, 400);
  }
  if (options.maxLength !== undefined && result.length > options.maxLength) {
    throw new RequestError(`${field} is too long`, 400);
  }
  return result;
}

export function requireUuid(value: unknown, field: string): string {
  const result = requireString(value, field, { maxLength: 36 });
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(result)) {
    throw new RequestError(`${field} must be a UUID`, 400);
  }
  return result;
}

export function boundedInteger(
  value: unknown,
  field: string,
  minimum: number,
  maximum: number,
  defaultValue?: number,
): number {
  if (value === undefined || value === null) {
    if (defaultValue !== undefined) return defaultValue;
    throw new RequestError(`${field} is required`, 400);
  }
  const numberValue = typeof value === "number" ? value : Number(value);
  if (!Number.isInteger(numberValue) || numberValue < minimum || numberValue > maximum) {
    throw new RequestError(`${field} must be an integer between ${minimum} and ${maximum}`, 400);
  }
  return numberValue;
}

export class RequestError extends Error {
  constructor(message: string, public readonly status = 400) {
    super(message);
    this.name = "RequestError";
  }
}

export function handleError(error: unknown): Response {
  if (error instanceof RequestError) {
    return jsonResponse({ error: error.message }, error.status);
  }
  console.error(error);
  return jsonResponse({ error: "Internal server error" }, 500);
}

export function sha256Hex(value: string | ArrayBuffer | Uint8Array): Promise<string> {
  const input = typeof value === "string" ? new TextEncoder().encode(value) : value;
  return crypto.subtle.digest("SHA-256", input as BufferSource).then((digest) =>
    Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")
  );
}
