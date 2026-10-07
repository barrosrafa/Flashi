import { strToU8, unzipSync, zipSync } from "fflate";
import { buildAnkiPackage, parseAnkiPackage, type AnkiTemplate, type ExportCard } from "../supabase/functions/_shared/anki-apkg.ts";

const basicTemplate: AnkiTemplate = {
  name: "Basic",
  ord: 0,
  qfmt: "{{Front}}",
  afmt: "{{FrontSide}}<hr id=answer>{{Back}}<div>{{Extra}}</div>",
  cardKind: "basic",
  clozeOrdinal: null,
};
const basicModel = {
  id: "basic-with-extra",
  name: "Basic with Extra",
  type: 0,
  fields: [{ name: "Front", ord: 0 }, { name: "Back", ord: 1 }, { name: "Extra", ord: 2 }],
  templates: [basicTemplate],
};
const clozeTemplates: AnkiTemplate[] = [
  { name: "Cloze 1", ord: 0, qfmt: "{{cloze:Text}}", afmt: "{{cloze:Text}}", cardKind: "cloze", clozeOrdinal: 1 },
  { name: "Cloze 2", ord: 1, qfmt: "{{cloze:Text}}", afmt: "{{cloze:Text}}", cardKind: "cloze", clozeOrdinal: 2 },
];
const clozeModel = {
  id: "cloze-model",
  name: "Cloze",
  type: 1,
  fields: [{ name: "Text", ord: 0 }, { name: "Extra", ord: 1 }],
  templates: clozeTemplates,
};

const binaryMedia = new Uint8Array([0, 255, 1, 2, 128, 13, 10, 0]);
const cards: ExportCard[] = [
  {
    id: "basic-card",
    noteId: "basic-note",
    deckId: "deck-basic",
    deckName: "F14 fixtures",
    fields: { Front: "Capital do Brasil", Back: "Brasília", Extra: '<img src="flag.bin">' },
    noteFields: { Front: "Capital do Brasil", Back: "Brasília", Extra: '<img src="flag.bin">' },
    tags: ["geography", "brasil"],
    cardOrdinal: 0,
    cardKind: "basic",
    template: basicTemplate,
    model: basicModel,
    media: [{ fieldName: "Extra", filename: "flag.bin", bytes: binaryMedia }],
  },
  {
    id: "cloze-card-1",
    noteId: "cloze-note",
    deckId: "deck-basic",
    deckName: "F14 fixtures",
    fields: { Text: "A capital é {{c1::Brasília}} e fica no {{c2::Brasil}}.", Extra: "keep" },
    noteFields: { Text: "A capital é {{c1::Brasília}} e fica no {{c2::Brasil}}.", Extra: "keep" },
    tags: ["cloze"],
    cardOrdinal: 0,
    cardKind: "cloze",
    clozeOrdinal: 1,
    template: clozeTemplates[0]!,
    model: clozeModel,
    media: [],
  },
  {
    id: "cloze-card-2",
    noteId: "cloze-note",
    deckId: "deck-basic",
    deckName: "F14 fixtures",
    fields: { Text: "A capital é {{c1::Brasília}} e fica no {{c2::Brasil}}.", Extra: "keep" },
    noteFields: { Text: "A capital é {{c1::Brasília}} e fica no {{c2::Brasil}}.", Extra: "keep" },
    tags: ["cloze"],
    cardOrdinal: 1,
    cardKind: "cloze",
    clozeOrdinal: 2,
    template: clozeTemplates[1]!,
    model: clozeModel,
    media: [],
  },
];

const bytes = await buildAnkiPackage(cards);
const archive = unzipSync(bytes);
if (!archive["collection.anki2"] || !archive["media"]) throw new Error("Missing core Anki files");
const parsed = await parseAnkiPackage(bytes);
if (parsed.notes.length !== 2) throw new Error(`Expected two grouped notes, got ${parsed.notes.length}`);
const basic = parsed.notes.find((note) => note.modelName === "Basic with Extra");
if (!basic || basic.cards.length !== 1) throw new Error("Basic note/card grouping mismatch");
if (basic.fields.Extra !== '<img src="flag.bin">') throw new Error("Basic Extra field mismatch");
if (basic.tags.join(" ") !== "geography brasil") throw new Error("Basic tags mismatch");
const mediaKey = Object.entries(parsed.media).find(([, filename]) => filename === "flag.bin")?.[0];
const archivedMedia = mediaKey ? archive[mediaKey] : undefined;
if (!mediaKey || !archivedMedia || archivedMedia.byteLength !== binaryMedia.byteLength || archivedMedia.some((byte: number, index: number) => byte !== binaryMedia[index])) {
  throw new Error("Binary media was not preserved byte-for-byte");
}
const cloze = parsed.notes.find((note) => note.modelName === "Cloze");
if (!cloze || cloze.cards.length !== 2) throw new Error("Cloze c1/c2 cards were not read from SQLite cards");
if (cloze.cards.map((card) => card.clozeOrdinal).join(",") !== "1,2") throw new Error("Cloze ordinals mismatch");
if (cloze.cards.some((card) => card.cardKind !== "cloze")) throw new Error("Cloze cards were classified as Basic");
if (cloze.cards.some((card) => !card.template.qfmt.includes("{{cloze:Text}}"))) throw new Error("Real Cloze templates were not preserved");

let anki21bError = "";
try {
  await parseAnkiPackage(zipSync({ "collection.anki21b": new Uint8Array([1, 2, 3]) }));
} catch (error) {
  anki21bError = error instanceof Error ? error.message : String(error);
}
if (!anki21bError.includes("collection.anki21b") || !anki21bError.includes("not supported")) throw new Error(".anki21b did not fail explicitly");

let zipSlipRejected = false;
try {
  await parseAnkiPackage(zipSync({ "../evil": strToU8("no") }));
} catch (error) {
  zipSlipRejected = error instanceof Error && error.message.includes("Unsafe path");
}
if (!zipSlipRejected) throw new Error("Zip-slip archive was not rejected");

console.log(JSON.stringify({
  bytes: bytes.byteLength,
  notes: parsed.notes.length,
  basicFields: Object.keys(basic.fields).length,
  clozeCards: cloze.cards.length,
  mediaBytes: binaryMedia.byteLength,
  anki21bError,
  zipSlipRejected,
}));
