import { unzipSync, zipSync, strToU8 } from "fflate";
import { buildAnkiPackage, parseAnkiPackage, type ExportCard } from "../supabase/functions/_shared/anki-apkg.ts";

const cards: ExportCard[] = [{
  id: "00000000-0000-4000-8000-000000000001",
  deckId: "00000000-0000-4000-8000-000000000002",
  deckName: "Round Trip",
  fields: { Front: "Capital do Brasil", Back: "Brasília", Extra: "<img src=\"flag.png\">" },
  tags: ["geography", "brasil"],
  media: [{ fieldName: "Extra", filename: "flag.png", bytes: new Uint8Array([137, 80, 78, 71, 13, 10]) }],
}];

const bytes = await buildAnkiPackage(cards);
const archive = unzipSync(bytes);
if (!archive["collection.anki2"] || !archive["media"]) throw new Error("Missing core Anki files");
const parsed = await parseAnkiPackage(bytes);
if (parsed.notes.length !== 1) throw new Error(`Expected 1 note, got ${parsed.notes.length}`);
if (parsed.notes[0]?.fields.Front !== "Capital do Brasil") throw new Error("Front field mismatch");
if (parsed.notes[0]?.tags.join(" ") !== "geography brasil") throw new Error("Tag mismatch");
if (parsed.media["0"] !== "flag.png") throw new Error("Media mapping mismatch");

let rejected = false;
try {
  await parseAnkiPackage(zipSync({ "../evil": strToU8("no") }));
} catch {
  rejected = true;
}
if (!rejected) throw new Error("Zip-slip archive was not rejected");
console.log(JSON.stringify({ bytes: bytes.byteLength, notes: parsed.notes.length, media: Object.keys(parsed.media).length, zipSlipRejected: rejected }));
