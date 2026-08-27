type FsrsModule = {
  Fsrs: typeof import("fsrs-browser").Fsrs;
  TrainingConfig: typeof import("fsrs-browser").TrainingConfig;
  initSync: (input: { module: ArrayBuffer }) => unknown;
};

export const MAX_REVIEWS = 25_000;
const DEFAULT_EPOCHS = 10;
const DEFAULT_BATCH_SIZE = 512;
const DEFAULT_MAX_SEQUENCE_LENGTH = 512;
const DEFAULT_LEARNING_RATE = 0.04;
const RATING_CODES: Record<string, number> = { again: 1, hard: 2, good: 3, easy: 4 };

let fsrsModule: FsrsModule | null = null;
let fsrsInitialization: Promise<void> | null = null;

function ensureWorkerGlobal(): void {
  const global = globalThis as unknown as { self?: unknown };
  if (!global.self) global.self = globalThis;
}

export async function initializeFsrs(): Promise<void> {
  if (!fsrsInitialization) {
    fsrsInitialization = (async () => {
      ensureWorkerGlobal();
      const module = await import("fsrs-browser") as unknown as FsrsModule;
      fsrsModule = module;
      const moduleUrl = import.meta.resolve("fsrs-browser");
      const wasmUrl = new URL("fsrs_browser_bg.wasm", moduleUrl);
      const response = await fetch(wasmUrl);
      if (!response.ok) throw new Error(`Unable to load FSRS WASM: ${response.status}`);
      const wasmBytes = await response.arrayBuffer();
      module.initSync({ module: wasmBytes });
    })();
  }
  return fsrsInitialization;
}

export function toFiniteWeights(value: unknown): number[] | undefined {
  if (!Array.isArray(value) || value.length !== 21) return undefined;
  const weights = value.map(Number);
  return weights.every(Number.isFinite) ? weights : undefined;
}

export function buildTrainingVectors(
  rows: Array<{ card_id: string; rating: string; reviewed_at: string }>,
): { ratings: Uint32Array; deltaTs: Uint32Array; lengths: Uint32Array; cardCount: number } {
  const groups = new Map<string, Array<{ rating: number; reviewedAt: number }>>();
  for (const row of rows) {
    const rating = RATING_CODES[row.rating];
    const reviewedAt = Date.parse(row.reviewed_at);
    if (!rating || !Number.isFinite(reviewedAt)) continue;
    const group = groups.get(row.card_id) ?? [];
    group.push({ rating, reviewedAt });
    groups.set(row.card_id, group);
  }

  const ratings: number[] = [];
  const deltaTs: number[] = [];
  const lengths: number[] = [];
  for (const group of groups.values()) {
    group.sort((left, right) => left.reviewedAt - right.reviewedAt);
    if (group.length === 0) continue;
    const firstReview = group[0];
    if (!firstReview) continue;
    let previous = firstReview.reviewedAt;
    for (let index = 0; index < group.length; index += 1) {
      const review = group[index];
      if (!review) continue;
      const deltaDays = index === 0
        ? 0
        : Math.max(0, Math.min(65_535, Math.round((review.reviewedAt - previous) / 86_400_000)));
      ratings.push(review.rating);
      deltaTs.push(deltaDays);
      previous = review.reviewedAt;
    }
    lengths.push(group.length);
  }

  if (ratings.length === 0 || lengths.length === 0) {
    throw new Error("At least one valid FSRS review is required");
  }
  return {
    ratings: new Uint32Array(ratings),
    deltaTs: new Uint32Array(deltaTs),
    lengths: new Uint32Array(lengths),
    cardCount: lengths.length,
  };
}

export async function optimizeWeights(
  rows: Array<{ card_id: string; rating: string; reviewed_at: string }>,
  oldWeights?: number[],
): Promise<{ weights: number[]; cardCount: number }> {
  const vectors = buildTrainingVectors(rows);
  await initializeFsrs();
  const module = fsrsModule;
  if (!module) throw new Error("FSRS module was not initialized");
  const optimizer = oldWeights ? new module.Fsrs(new Float32Array(oldWeights)) : new module.Fsrs();
  const trainingConfig = module.TrainingConfig.withValues(
    DEFAULT_EPOCHS,
    DEFAULT_BATCH_SIZE,
    42n,
    DEFAULT_LEARNING_RATE,
    DEFAULT_MAX_SEQUENCE_LENGTH,
    0,
  );
  const parameters = optimizer.computeParameters(
    vectors.ratings,
    vectors.deltaTs,
    vectors.lengths,
    null,
    false,
    null,
    0,
    trainingConfig,
  );
  optimizer.free();

  const weights = Array.from(parameters, Number);
  if (weights.length !== 21 || weights.some((weight) => !Number.isFinite(weight))) {
    throw new Error("FSRS optimizer returned invalid parameters");
  }
  return { weights, cardCount: vectors.cardCount };
}
