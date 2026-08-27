const ALLOWED_ORIGINS = new Set(
  (Deno.env.get("ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean),
);

const ALLOW_HEADERS = "authorization, x-client-info, apikey, content-type";
const ALLOW_METHODS = "POST, OPTIONS";

export function getRequestId(request: Request): string {
  const supplied = request.headers.get("x-request-id")?.trim();
  return supplied && supplied.length <= 120 ? supplied : crypto.randomUUID();
}

export function getCorsHeaders(request?: Request): Record<string, string> {
  const origin = request?.headers.get("Origin")?.trim();
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers": ALLOW_HEADERS,
    "Access-Control-Allow-Methods": ALLOW_METHODS,
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
  if (origin && ALLOWED_ORIGINS.has(origin)) headers["Access-Control-Allow-Origin"] = origin;
  return headers;
}

export function handleCors(request: Request): Response | null {
  if (request.method !== "OPTIONS") return null;
  return new Response(null, { status: 204, headers: getCorsHeaders(request) });
}

export function jsonResponse(
  request: Request,
  body: unknown,
  status = 200,
  headers: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...getCorsHeaders(request),
      "Content-Type": "application/json; charset=utf-8",
      ...headers,
    },
  });
}

export function errorResponse(request: Request, message: string, status: number, code: string): Response {
  return jsonResponse(request, { error: message, code, request_id: getRequestId(request) }, status);
}

export async function readJson(request: Request, maxBytes = 1_000_000): Promise<unknown> {
  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > maxBytes) {
    throw new RequestError("Request body is too large", 413, "PAYLOAD_TOO_LARGE");
  }
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > maxBytes) {
    throw new RequestError("Request body is too large", 413, "PAYLOAD_TOO_LARGE");
  }
  if (!text.trim()) return {};
  try {
    return JSON.parse(text);
  } catch {
    throw new RequestError("Request body must be valid JSON", 400, "VALIDATION_ERROR");
  }
}

export function requireRecord(value: unknown, message = "Request body must be an object"): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new RequestError(message, 400, "VALIDATION_ERROR");
  }
  return value as Record<string, unknown>;
}

export function requireString(value: unknown, field: string, options: { maxLength?: number; allowEmpty?: boolean } = {}): string {
  if (typeof value !== "string") throw new RequestError(`${field} must be a string`, 400, "VALIDATION_ERROR");
  const result = value.trim();
  if (!options.allowEmpty && result.length === 0) throw new RequestError(`${field} cannot be empty`, 400, "VALIDATION_ERROR");
  if (options.maxLength !== undefined && result.length > options.maxLength) throw new RequestError(`${field} is too long`, 400, "VALIDATION_ERROR");
  return result;
}

export function requireUuid(value: unknown, field: string): string {
  const result = requireString(value, field, { maxLength: 36 });
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(result)) {
    throw new RequestError(`${field} must be a UUID`, 400, "VALIDATION_ERROR");
  }
  return result;
}

export function boundedInteger(value: unknown, field: string, minimum: number, maximum: number, defaultValue?: number): number {
  if (value === undefined || value === null) {
    if (defaultValue !== undefined) return defaultValue;
    throw new RequestError(`${field} is required`, 400, "VALIDATION_ERROR");
  }
  const numberValue = typeof value === "number" ? value : Number(value);
  if (!Number.isInteger(numberValue) || numberValue < minimum || numberValue > maximum) {
    throw new RequestError(`${field} must be an integer between ${minimum} and ${maximum}`, 400, "VALIDATION_ERROR");
  }
  return numberValue;
}

export class RequestError extends Error {
  constructor(message: string, public readonly status = 400, public readonly code = codeForStatus(status)) {
    super(message);
    this.name = "RequestError";
  }
}

function codeForStatus(status: number): string {
  if (status === 400 || status === 422) return "VALIDATION_ERROR";
  if (status === 401) return "UNAUTHENTICATED";
  if (status === 403) return "FORBIDDEN";
  if (status === 404) return "NOT_FOUND";
  if (status === 409) return "CONFLICT";
  if (status === 429) return "RATE_LIMITED";
  if (status >= 500 && status < 600) return "INTERNAL_ERROR";
  return "REQUEST_ERROR";
}

export function handleError(error: unknown, request: Request): Response {
  const requestId = getRequestId(request);
  if (error instanceof RequestError) {
    return jsonResponse(request, { error: error.message, code: error.code, request_id: requestId }, error.status);
  }
  console.error(JSON.stringify({ request_id: requestId, error }));
  return jsonResponse(request, { error: "Internal server error", code: "INTERNAL_ERROR", request_id: requestId }, 500);
}

export function sha256Hex(value: string | ArrayBuffer | Uint8Array): Promise<string> {
  const input = typeof value === "string" ? new TextEncoder().encode(value) : value;
  return crypto.subtle.digest("SHA-256", input as BufferSource).then((digest) =>
    Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")
  );
}
