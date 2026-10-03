import { createUserClient, requireUserId } from "../_shared/supabase.ts";
import { errorResponse, handleCors, handleError, jsonResponse, readJson, requireRecord, requireString, requireUuid, RequestError } from "../_shared/http.ts";

type Card = { fields: { Front: string; Back: string }; card_kind: "basic"; card_ordinal: number; cloze_ordinal: null };
type Note = { fields: { Front: string; Back: string }; cards: Card[] };
const FORMATS = new Set(["csv", "markdown", "quizlet", "remnote"]);
const MAX_BYTES = 15 * 1024 * 1024;
function csv(text: string): Note[] {
  return text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean).map((line, i) => {
    const parts = line.split(",").map((part) => part.trim().replace(/^"|"$/g, ""));
    if (i === 0 && /^front$/i.test(parts[0] ?? "") && /^back$/i.test(parts[1] ?? "")) return null;
    if (!parts[0] || !parts[1]) throw new RequestError("CSV rows require Front and Back", 422);
    return note(parts[0], parts.slice(1).join(","), i);
  }).filter((item): item is Note => item !== null);
}
function markdown(text: string): Note[] {
  const result: Note[] = []; let front = ""; let back: string[] = [];
  for (const line of text.split(/\r?\n/)) {
    if (/^#{1,6}\s+/.test(line)) { if (front && back.join(" ").trim()) result.push(note(front, back.join(" "), result.length)); front = line.replace(/^#{1,6}\s+/, "").trim(); back = []; }
    else if (/^\s*[-*]\s+/.test(line)) back.push(line.replace(/^\s*[-*]\s+/, "").trim());
    else if (line.trim()) { if (!front) front = line.trim(); else back.push(line.trim()); }
  }
  if (front && back.join(" ").trim()) result.push(note(front, back.join(" "), result.length));
  return result;
}
function note(front: string, back: string, ordinal: number): Note { return { fields: { Front: front, Back: back }, cards: [{ fields: { Front: front, Back: back }, card_kind: "basic", card_ordinal: ordinal, cloze_ordinal: null }] }; }
function parse(text: string, format: string): Note[] { if (format === "csv" || format === "quizlet") return csv(text); return markdown(text); }
Deno.serve(async (request) => {
  const cors = handleCors(request); if (cors) return cors;
  if (request.method !== "POST") return errorResponse(request, "Method not allowed", 405, "METHOD_NOT_ALLOWED");
  try {
    const client = createUserClient(request); const userId = await requireUserId(client);
    const body = requireRecord(await readJson(request, 1_000_000));
    const deckId = requireUuid(body.deck_id ?? body.deckId, "deck_id");
    const format = requireString(body.format, "format", { maxLength: 16 }).toLowerCase();
    if (!FORMATS.has(format)) throw new RequestError("format must be csv, markdown, quizlet or remnote", 400);
    const storagePath = requireString(body.storage_path ?? body.storagePath, "storage_path", { maxLength: 500 });
    if (!storagePath.startsWith(`${userId}/`) || storagePath.startsWith("/") || storagePath.includes("..")) throw new RequestError("storage_path must be under the authenticated user's directory", 400);
    const { data: deck, error: deckError } = await client.from("decks").select("id").eq("id", deckId).eq("user_id", userId).maybeSingle();
    if (deckError) throw new Error(deckError.message); if (!deck) throw new RequestError("Deck not found", 404);
    const { data: signed, error: signedError } = await client.storage.from("import-media").createSignedUrl(storagePath, 300);
    if (signedError || !signed?.signedUrl) throw new RequestError("Unable to create signed import URL", 404);
    const download = await fetch(signed.signedUrl); if (!download.ok) throw new RequestError("Import file unavailable", 404);
    if (Number(download.headers.get("content-length") ?? 0) > MAX_BYTES) throw new RequestError("Import file exceeds 15 MiB", 413);
    const notes = parse(await download.text(), format); if (notes.length === 0) throw new RequestError("Import contains no cards", 422);
    const { data: job, error: jobError } = await client.from("deck_import_jobs").insert({ user_id: userId, deck_id: deckId, format, storage_path: storagePath, status: "processing" }).select("id").single();
    if (jobError) throw new Error(jobError.message);
    const { data: materialized, error: materializeError } = await client.rpc("materialize_import_batch", { p_job_id: job.id, p_user_id: userId, p_deck_id: deckId, p_notes: notes });
    if (materializeError) throw new Error(materializeError.message);
    return jsonResponse(request, { job_id: job.id, status: "completed", notes_count: materialized?.[0]?.notes_count ?? notes.length, cards_count: materialized?.[0]?.cards_count ?? notes.length });
  } catch (error) { return handleError(error, request); }
});
