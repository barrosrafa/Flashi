import sqlite3InitModule from "@sqlite.org/sqlite-wasm";
import { strFromU8, strToU8, unzipSync, zipSync } from "fflate";

const FIELD_SEPARATOR = "\u001f";
const MAX_ARCHIVE_ENTRIES = 20_000;
const MAX_PACKAGE_BYTES = 50 * 1024 * 1024;

// SQLite values returned by sqlite-wasm's object row mode.
type SqlValue = string | number | bigint | Uint8Array | null;
type SqlRow = Record<string, SqlValue>;

export type AnkiTemplate = {
  name: string;
  ord: number;
  qfmt: string;
  afmt: string;
  cardKind: "basic" | "reverse" | "cloze";
  clozeOrdinal: number | null;
};

type AnkiModel = {
  id?: number;
  name?: string;
  type?: number;
  flds?: Array<{ name?: string; ord?: number }>;
  tmpls?: Array<{ name?: string; ord?: number; qfmt?: string; afmt?: string }>;
  css?: string;
};

export type ParsedAnkiCard = {
  /** The actual SQLite cards.id, not a template-generated synthetic id. */
  externalId: string;
  ordinal: number;
  front: string;
  back: string;
  cardKind: "basic" | "reverse" | "cloze";
  clozeOrdinal: number | null;
  template: AnkiTemplate;
};

export type ParsedAnkiNote = {
  /** The actual SQLite notes.id. */
  externalId: string;
  modelId: string;
  modelName: string;
  modelType: number;
  css: string;
  fieldOrder: string[];
  modifiedAt: number;
  fields: Record<string, string>;
  tags: string[];
  /** Only cards present in SQLite cards are returned; no template inference. */
  cards: ParsedAnkiCard[];
  templates: AnkiTemplate[];
};

export type ParsedAnkiPackage = {
  notes: ParsedAnkiNote[];
  /** Anki's media manifest: numeric archive key -> original filename. */
  media: Record<string, string>;
  files: Record<string, Uint8Array>;
};

function asString(value: SqlValue | undefined): string {
  if (value === null || value === undefined) return "";
  return String(value);
}

function asNumber(value: SqlValue | undefined): number {
  const numberValue = Number(value);
  return Number.isFinite(numberValue) ? numberValue : 0;
}

function jsonObject(value: string, label: string): Record<string, unknown> {
  try {
    const parsed = JSON.parse(value) as unknown;
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      throw new Error(`${label} must be an object`);
    }
    return parsed as Record<string, unknown>;
  } catch {
    throw new Error(`Invalid ${label} JSON in Anki package`);
  }
}

/** Reject absolute paths and every dot/dot-dot path segment (ZIP slip). */
function safeArchiveName(name: string): string {
  const normalized = name.replaceAll("\\", "/");
  if (!normalized || normalized.startsWith("/") || /^[A-Za-z]:\//.test(normalized) || normalized.includes("\u0000")) {
    throw new Error(`Unsafe path in Anki ZIP archive: ${name}`);
  }
  const segments = normalized.split("/");
  if (segments.some((segment) => segment === ".." || segment === "." || /[\u0000-\u001f]/.test(segment))) {
    throw new Error(`Unsafe path in Anki ZIP archive: ${name}`);
  }
  return normalized;
}

function clozeText(value: string, ordinal: number | null, reveal: boolean): string {
  if (ordinal === null) return value;
  return value.replace(/\{\{c(\d+)::([\s\S]*?)(?:::(.*?))?\}\}/gi, (_match, rawOrdinal, body, hint) => {
    const current = Number(rawOrdinal);
    if (reveal || current !== ordinal) return String(body);
    const cleanHint = typeof hint === "string" && hint.length > 0 ? `...${hint}` : "[...]";
    return cleanHint;
  });
}

/** Render the Anki subset represented by the stored model metadata. */
function renderAnki(
  template: string,
  fields: Record<string, string>,
  frontSide = "",
  clozeOrdinal: number | null = null,
  revealCloze = false,
): string {
  let rendered = template;
  rendered = rendered.replace(/\{\{#([^}]+)\}\}([\s\S]*?)\{\{\/\1\}\}/g, (_match, field, body) =>
    fields[String(field).trim()] ? body : "");
  rendered = rendered.replace(/\{\{\^([^}]+)\}\}([\s\S]*?)\{\{\/\1\}\}/g, (_match, field, body) =>
    fields[String(field).trim()] ? "" : body);
  rendered = rendered.replace(/\{\{FrontSide\}\}/g, frontSide);
  rendered = rendered.replace(/\{\{cloze:([^}]+)\}\}/gi, (_match, field) =>
    clozeText(fields[String(field).trim()] ?? "", clozeOrdinal, revealCloze));
  rendered = rendered.replace(/\{\{(?:type|text):([^}]+)\}\}/gi, (_match, field) =>
    fields[String(field).trim()] ?? "");
  // Some exported/custom models put a literal cloze marker in a template.
  rendered = clozeText(rendered, clozeOrdinal, revealCloze);
  rendered = rendered.replace(/\{\{([^}]+)\}\}/g, (_match, field) => fields[String(field).trim()] ?? "");
  return rendered;
}

function parseMediaMap(files: Record<string, Uint8Array>): Record<string, string> {
  const mediaBytes = files.media;
  if (!mediaBytes) return {};
  const raw = strFromU8(mediaBytes);
  const parsed = jsonObject(raw, "media");
  const result: Record<string, string> = {};
  const filenameToArchive = new Map<string, string>();
  for (const [key, value] of Object.entries(parsed)) {
    if (!/^\d+$/.test(key)) throw new Error(`Invalid Anki media archive key: ${key}`);
    if (typeof value !== "string" || !value) throw new Error(`Invalid Anki media filename for archive key ${key}`);
    const filename = safeArchiveName(value);
    const mediaFile = files[key];
    if (!mediaFile) throw new Error(`Anki media manifest references missing archive entry ${key}`);
    const previousKey = filenameToArchive.get(filename);
    if (previousKey && previousKey !== key) {
      throw new Error(`Anki media manifest maps ${filename} more than once; cannot preserve bytes unambiguously`);
    }
    filenameToArchive.set(filename, key);
    result[key] = filename;
  }
  return result;
}

async function openSqlite(bytes: Uint8Array): Promise<{ sqlite3: any; db: any }> {
  const sqlite3 = await sqlite3InitModule();
  const db = new sqlite3.oo1.DB(":memory:", "c");
  const pointer = sqlite3.wasm.allocFromTypedArray(bytes);
  const flags = sqlite3.capi.SQLITE_DESERIALIZE_FREEONCLOSE |
    sqlite3.capi.SQLITE_DESERIALIZE_RESIZEABLE;
  const dbPointer = db.pointer as number | undefined;
  if (dbPointer === undefined) {
    db.close();
    throw new Error("Unable to obtain SQLite database pointer");
  }
  const result = sqlite3.capi.sqlite3_deserialize(
    dbPointer,
    "main",
    pointer,
    bytes.byteLength,
    bytes.byteLength,
    flags,
  );
  if (result !== 0) {
    db.close();
    throw new Error(`Unable to open Anki SQLite database (code ${result})`);
  }
  return { sqlite3, db };
}

function findCollection(files: Record<string, Uint8Array>): Uint8Array {
  if (files["collection.anki21b"]) {
    throw new Error("collection.anki21b is not supported yet; export a legacy .apkg with collection.anki2 or collection.anki21 from Anki");
  }
  for (const filename of ["collection.anki2", "collection.anki21"]) {
    if (files[filename]) return files[filename];
  }
  throw new Error("Anki package does not contain collection.anki2 or collection.anki21");
}

function modelTemplates(model: AnkiModel): AnkiTemplate[] {
  const templates = Array.isArray(model.tmpls) ? model.tmpls : [];
  return templates
    .map((template, index) => {
      const ord = Number.isInteger(template.ord) ? Number(template.ord) : index;
      const qfmt = String(template.qfmt ?? "");
      const afmt = String(template.afmt ?? "");
      const cloze = model.type === 1 || /\{\{cloze:/i.test(`${qfmt}${afmt}`);
      return {
        name: String(template.name ?? `Card ${ord + 1}`),
        ord,
        qfmt,
        afmt,
        cardKind: cloze ? "cloze" : "basic",
        clozeOrdinal: null,
      } satisfies AnkiTemplate;
    })
    .sort((left, right) => left.ord - right.ord);
}

export async function parseAnkiPackage(bytes: Uint8Array): Promise<ParsedAnkiPackage> {
  if (bytes.byteLength === 0 || bytes.byteLength > MAX_PACKAGE_BYTES) {
    throw new Error(`Anki package must be between 1 byte and ${MAX_PACKAGE_BYTES} bytes`);
  }
  const files = unzipSync(bytes);
  const safeFiles: Record<string, Uint8Array> = {};
  for (const rawName of Object.keys(files)) {
    const filename = safeArchiveName(rawName);
    if (safeFiles[filename]) throw new Error(`Duplicate path in Anki ZIP archive: ${filename}`);
    const file = files[rawName];
    if (file) safeFiles[filename] = file;
  }
  if (Object.keys(safeFiles).length > MAX_ARCHIVE_ENTRIES) throw new Error("Anki package has too many entries");

  const { db } = await openSqlite(findCollection(safeFiles));
  try {
    const modelsRaw = asString(db.selectValue("select models from col limit 1"));
    const models = jsonObject(modelsRaw, "models");
    // The cards join is intentional: templates describe possible cards, while
    // cards.ord is the source of truth for cards actually present in APKG.
    const rows = db.exec({
      sql: "select n.id as nid, n.mid, n.flds, n.tags, n.mod, c.id as cid, c.ord as card_ord from notes n left join cards c on c.nid = n.id order by n.id, c.ord, c.id",
      rowMode: "object",
      returnValue: "resultRows",
    }) as SqlRow[];
    const notes: ParsedAnkiNote[] = [];
    let current: ParsedAnkiNote | null = null;

    for (const row of rows) {
      const nid = asString(row.nid);
      if (!nid) continue;
      if (!current || current.externalId !== `anki:${nid}`) {
        const modelId = asString(row.mid);
        const model = (models[modelId] ?? {}) as AnkiModel;
        const modelFields = Array.isArray(model.flds) ? model.flds.slice().sort((a, b) => Number(a.ord ?? 0) - Number(b.ord ?? 0)) : [];
        const fieldOrder: string[] = [];
        const fields: Record<string, string> = {};
        const rawFields = asString(row.flds).split(FIELD_SEPARATOR);
        for (let index = 0; index < Math.max(modelFields.length, rawFields.length); index += 1) {
          const fieldName = modelFields[index]?.name?.trim() || `Field${index + 1}`;
          if (fieldOrder.includes(fieldName)) throw new Error(`Anki note ${nid} has duplicate model field ${fieldName}; cannot preserve fields by name`);
          fieldOrder.push(fieldName);
          fields[fieldName] = rawFields[index] ?? "";
        }
        current = {
          externalId: `anki:${nid}`,
          modelId,
          modelName: String(model.name ?? `Anki model ${modelId}`),
          modelType: Number(model.type ?? 0),
          css: String(model.css ?? ""),
          fieldOrder,
          modifiedAt: asNumber(row.mod),
          fields,
          tags: asString(row.tags).trim().split(/\s+/).filter(Boolean),
          cards: [],
          templates: modelTemplates(model),
        };
        notes.push(current);
      }

      // A note with no cards is retained for diagnostics, but import refuses it
      // rather than silently creating a synthetic Basic card.
      if (row.cid !== null && row.cid !== undefined) {
        const ordinal = asNumber(row.card_ord);
        if (!Number.isInteger(ordinal) || ordinal < 0) throw new Error(`Anki card ${asString(row.cid)} has invalid ordinal`);
        const template = current.templates.find((candidate) => candidate.ord === ordinal);
        if (!template) {
          throw new Error(`Anki note ${current.externalId} card ordinal ${ordinal} has no matching model template; export the note with its model metadata intact`);
        }
        const isCloze = current.modelType === 1 || template.cardKind === "cloze";
        const actualTemplate: AnkiTemplate = {
          ...template,
          cardKind: isCloze ? "cloze" : template.cardKind,
          clozeOrdinal: isCloze ? ordinal + 1 : null,
        };
        const front = renderAnki(actualTemplate.qfmt, current.fields, "", actualTemplate.clozeOrdinal, false);
        const back = renderAnki(actualTemplate.afmt, current.fields, front, actualTemplate.clozeOrdinal, true);
        current.cards.push({
          externalId: `anki:${asString(row.cid)}`,
          ordinal,
          front,
          back,
          cardKind: actualTemplate.cardKind,
          clozeOrdinal: actualTemplate.clozeOrdinal,
          template: actualTemplate,
        });
      }
    }
    return { notes, media: parseMediaMap(safeFiles), files: safeFiles };
  } finally {
    db.close();
  }
}

function sqlText(value: string): string {
  return value.replaceAll("\\", "\\\\");
}

function numericId(value: string, fallback: number): number {
  let hash = 2166136261;
  for (const char of value) hash = Math.imul(hash ^ char.charCodeAt(0), 16777619);
  const normalized = Math.abs(hash >>> 0);
  return normalized > 0 ? normalized : fallback;
}

function uniqueNumericId(value: string, fallback: number, used: Set<number>): number {
  let candidate = numericId(value, fallback);
  while (used.has(candidate)) candidate = candidate >= 2_000_000_000 ? fallback + used.size + 1 : candidate + 1;
  used.add(candidate);
  return candidate;
}

function exportFilename(name: string): string {
  const normalized = name.replaceAll("\\", "/");
  if (!normalized || normalized.startsWith("/") || normalized.split("/").some((segment) => segment === ".." || segment === "." || segment === "")) {
    throw new Error(`Invalid Anki media filename ${name}; cannot preserve media safely`);
  }
  return normalized;
}

export type AnkiExportModel = {
  id?: string;
  name?: string;
  type?: number;
  css?: string;
  fields?: Array<{ name: string; ord?: number }>;
  templates?: AnkiTemplate[];
};

export type ExportCard = {
  id: string;
  /** Cards with the same noteId are emitted as cards of one Anki note. */
  noteId?: string;
  deckId: string;
  deckName: string;
  fields: Record<string, unknown>;
  /** Optional model/note fields; fields remains the backwards-compatible fallback. */
  noteFields?: Record<string, unknown>;
  tags: string[];
  cardOrdinal?: number;
  cardKind?: "basic" | "reverse" | "cloze";
  clozeOrdinal?: number | null;
  template?: AnkiTemplate;
  model?: AnkiExportModel;
  media: Array<{ fieldName: string | null; filename: string; bytes: Uint8Array; sha256?: string }>;
};

type ExportGroup = {
  noteId: string;
  deckId: string;
  deckName: string;
  fields: Record<string, unknown>;
  tags: string[];
  model: AnkiExportModel;
  cards: ExportCard[];
};

function mergeTags(cards: ExportCard[]): string[] {
  const tags: string[] = [];
  const seen = new Set<string>();
  for (const card of cards) {
    for (const tag of card.tags) {
      if (!seen.has(tag)) {
        seen.add(tag);
        tags.push(tag);
      }
    }
  }
  return tags;
}

function modelForGroup(groupCards: ExportCard[]): AnkiExportModel {
  const supplied = groupCards.find((card) => card.model)?.model;
  const fields = supplied?.fields?.length
    ? supplied.fields
    : Object.keys(groupCards[0]?.noteFields ?? groupCards[0]?.fields ?? {}).map((name, ord) => ({ name, ord }));
  const templates = supplied?.templates?.length
    ? supplied.templates
    : groupCards.filter((card) => card.template).map((card) => card.template as AnkiTemplate);
  return {
    id: supplied?.id,
    name: supplied?.name ?? "Flashi Basic",
    type: supplied?.type ?? (templates.some((template) => template.cardKind === "cloze") ? 1 : 0),
    css: supplied?.css ?? ".card { font-family: arial; font-size: 20px; text-align: center; color: black; background-color: white; }",
    fields,
    templates,
  };
}

function templatesForGroup(group: ExportGroup): AnkiTemplate[] {
  const fieldNames = Object.keys(group.fields);
  if (fieldNames.length === 0) throw new Error(`Anki note ${group.noteId} has no fields to export`);
  const templates = group.model.templates?.slice().sort((a, b) => a.ord - b.ord) ?? [];
  const highestOrdinal = Math.max(...group.cards.map((card, index) => Number.isInteger(card.cardOrdinal) ? Number(card.cardOrdinal) : index), 0);
  const result = templates.slice();
  for (let ordinal = 0; ordinal <= highestOrdinal; ordinal += 1) {
    if (result.some((template) => template.ord === ordinal)) continue;
    const card = group.cards.find((candidate, index) => (Number.isInteger(candidate.cardOrdinal) ? Number(candidate.cardOrdinal) : index) === ordinal);
    if (!card) throw new Error(`Anki note ${group.noteId} has card ordinal ${ordinal} without template metadata; cannot invent a card template`);
    const first = fieldNames[0] ?? "Front";
    const second = fieldNames[1] ?? first;
    result.push({
      name: `Card ${ordinal + 1}`,
      ord: ordinal,
      qfmt: `{{${first}}}`,
      afmt: `{{FrontSide}}<hr id=answer>{{${second}}}`,
      cardKind: card.cardKind ?? "basic",
      clozeOrdinal: card.cardKind === "cloze" ? (card.clozeOrdinal ?? ordinal + 1) : null,
    });
  }
  return result.sort((left, right) => left.ord - right.ord);
}

export async function buildAnkiPackage(cards: ExportCard[]): Promise<Uint8Array> {
  if (cards.length === 0) throw new Error("At least one card is required for Anki export");
  const sqlite3 = await sqlite3InitModule();
  const db = new sqlite3.oo1.DB(":memory:", "c");
  const now = Math.floor(Date.now() / 1000);
  const groups = new Map<string, ExportGroup>();
  for (const card of cards) {
    const noteId = card.noteId ?? card.id;
    const existing = groups.get(noteId);
    if (existing) {
      if (existing.deckId !== card.deckId) throw new Error(`Cards in note ${noteId} belong to different decks`);
      existing.cards.push(card);
      existing.tags = mergeTags(existing.cards);
    } else {
      const fields = card.noteFields ?? card.fields;
      groups.set(noteId, {
        noteId,
        deckId: card.deckId,
        deckName: card.deckName,
        fields,
        tags: card.tags.slice(),
        model: modelForGroup([card]),
        cards: [card],
      });
    }
  }
  for (const group of groups.values()) {
    group.model = modelForGroup(group.cards);
    group.tags = mergeTags(group.cards);
    const fieldNames = Object.keys(group.fields);
    group.model.fields = (group.model.fields?.length ? group.model.fields : fieldNames.map((name, ord) => ({ name, ord }))).map((field, index) => ({ name: field.name, ord: field.ord ?? index }));
    group.model.templates = templatesForGroup(group);
  }

  const deckIds = new Map<string, number>();
  const usedDeckIds = new Set<number>();
  for (const card of cards) {
    if (!deckIds.has(card.deckId)) deckIds.set(card.deckId, uniqueNumericId(card.deckId, deckIds.size + 1, usedDeckIds));
  }
  const deckObject: Record<string, unknown> = {};
  for (const group of groups.values()) {
    const did = deckIds.get(group.deckId) ?? 1;
    deckObject[String(did)] = {
      id: did,
      name: group.deckName.slice(0, 120),
      desc: "Exported from Flashi",
      dyn: 0,
      collapsed: false,
      conf: 1,
      extendNew: 10,
      extendRev: 50,
      mod: now,
      usn: -1,
      newToday: [now, 0],
      revToday: [now, 0],
      lrnToday: [now, 0],
    };
  }

  const modelIds = new Map<string, number>();
  const usedModelIds = new Set<number>();
  const modelObject: Record<string, unknown> = {};
  for (const group of groups.values()) {
    const modelKey = JSON.stringify({ id: group.model.id ?? "", name: group.model.name, fields: group.model.fields, templates: group.model.templates });
    if (!modelIds.has(modelKey)) {
      const modelId = uniqueNumericId(group.model.id ?? modelKey, 1_600_000_000 + modelIds.size, usedModelIds);
      modelIds.set(modelKey, modelId);
      const modelFields = group.model.fields ?? [];
      const modelTemplates = group.model.templates ?? [];
      modelObject[String(modelId)] = {
        id: modelId,
        name: String(group.model.name ?? "Flashi Basic").slice(0, 120),
        type: group.model.type ?? 0,
        mod: now,
        usn: -1,
        sortf: 0,
        did: null,
        flds: modelFields.map((field, index) => ({ name: field.name, ord: field.ord ?? index, sticky: false, rtl: false, font: "Arial", size: 20 })),
        tmpls: modelTemplates.map((template) => ({ name: template.name, ord: template.ord, qfmt: template.qfmt, afmt: template.afmt, did: null, bqfmt: "", bafmt: "" })),
        css: String(group.model.css ?? ""),
        latexPre: "",
        latexPost: "",
        req: modelTemplates.map((template) => [template.ord, template.cardKind === "cloze" ? "any" : "all", modelFields.map((_field, index) => index)]),
      };
    }
  }

  db.exec(`
    pragma user_version = 11;
    create table col (id integer primary key, crt integer not null, mod integer not null, scm integer not null, ver integer not null, dty integer not null, usn integer not null, ls integer not null, conf text not null, models text not null, decks text not null, dconf text not null, tags text not null);
    create table notes (id integer primary key, guid text not null, mid integer not null, mod integer not null, usn integer not null, tags text not null, flds text not null, sfld integer not null, csum integer not null, flags integer not null, data text not null);
    create table cards (id integer primary key, nid integer not null, did integer not null, ord integer not null, mod integer not null, usn integer not null, type integer not null, queue integer not null, due integer not null, ivl integer not null, factor integer not null, reps integer not null, lapses integer not null, left integer not null, odue integer not null, odid integer not null, flags integer not null, data text not null);
    create table revlog (id integer primary key, cid integer not null, usn integer not null, ease integer not null, ivl integer not null, lastIvl integer not null, factor integer not null, time integer not null, type integer not null);
    create index ix_notes_usn on notes (usn);
    create index ix_cards_usn on cards (usn);
    create index ix_cards_nid on cards (nid);
    create index ix_revlog_usn on revlog (usn);
    create index ix_revlog_cid on revlog (cid);
  `);
  db.exec({
    sql: "insert into col values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    bind: [1, now, now, Date.now(), 11, 0, -1, 0, JSON.stringify({}), JSON.stringify(modelObject), JSON.stringify(deckObject), JSON.stringify({}), "{}"],
  });

  const archive: Record<string, Uint8Array> = {};
  const media: Record<string, string> = {};
  const mediaByFilename = new Map<string, { archiveKey: string; bytes: Uint8Array }>();
  let mediaIndex = 0;
  let noteIndex = 0;
  for (const group of groups.values()) {
    noteIndex += 1;
    const nid = 1_000_000_000 + noteIndex;
    const modelKey = JSON.stringify({ id: group.model.id ?? "", name: group.model.name, fields: group.model.fields, templates: group.model.templates });
    const mid = modelIds.get(modelKey);
    if (!mid) throw new Error(`Missing Anki model for note ${group.noteId}`);
    const did = deckIds.get(group.deckId) ?? 1;
    const fields = group.model.fields ?? Object.keys(group.fields).map((name, ord) => ({ name, ord }));
    const values = fields.map((field) => String(group.fields[field.name] ?? ""));
    const tags = group.tags.map((tag) => {
      if (!tag || /\s/.test(tag) || tag.length > 60) throw new Error(`Anki tag ${tag || "(empty)"} cannot be represented by Flashi's tag schema without loss`);
      return tag;
    }).join(" ");
    db.exec({
      sql: "insert into notes values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      bind: [nid, `flashi-${group.noteId}`, mid, now, -1, tags, values.join(FIELD_SEPARATOR), values[0] ?? "", 0, 0, ""],
    });
    const usedOrdinals = new Set<number>();
    group.cards.forEach((card, index) => {
      const ordinal = Number.isInteger(card.cardOrdinal) ? Number(card.cardOrdinal) : index;
      if (ordinal < 0 || usedOrdinals.has(ordinal)) throw new Error(`Anki note ${group.noteId} has duplicate or invalid card ordinal ${ordinal}`);
      usedOrdinals.add(ordinal);
      const cid = nid * 100 + index + 1;
      const cardTemplate = group.model.templates?.find((template) => template.ord === ordinal);
      if (!cardTemplate) throw new Error(`Anki note ${group.noteId} card ordinal ${ordinal} has no template metadata; refusing to invent a card`);
      db.exec({
        sql: "insert into cards values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        bind: [cid, nid, did, ordinal, now, -1, group.model.type === 1 ? 1 : 0, 0, index + 1, 0, 0, 0, 0, 0, 0, 0, 0, ""],
      });
      for (const item of card.media) {
        const filename = exportFilename(item.filename);
        const existing = mediaByFilename.get(filename);
        if (existing) {
          if (existing.bytes.byteLength !== item.bytes.byteLength || existing.bytes.some((value, byteIndex) => value !== item.bytes[byteIndex])) {
            throw new Error(`Anki media filename ${filename} has different bytes in the same export; refusing ambiguous media`);
          }
        } else {
          const archiveKey = String(mediaIndex++);
          mediaByFilename.set(filename, { archiveKey, bytes: item.bytes });
          media[archiveKey] = filename;
          archive[archiveKey] = item.bytes;
        }
      }
    });
  }
  archive["media"] = strToU8(JSON.stringify(media));
  const dbPointer = db.pointer as number | undefined;
  if (dbPointer === undefined) {
    db.close();
    throw new Error("Unable to obtain SQLite database pointer for export");
  }
  archive["collection.anki2"] = sqlite3.capi.sqlite3_js_db_export(dbPointer);
  db.close();
  return zipSync(archive, { level: 6 });
}
