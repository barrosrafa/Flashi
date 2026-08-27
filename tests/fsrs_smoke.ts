import { optimizeWeights } from "../supabase/functions/_shared/fsrs-optimizer.ts";

const rows = [
  { card_id: "card-1", rating: "good", reviewed_at: "2026-01-01T00:00:00.000Z" },
  { card_id: "card-1", rating: "easy", reviewed_at: "2026-01-03T00:00:00.000Z" },
  { card_id: "card-1", rating: "hard", reviewed_at: "2026-01-08T00:00:00.000Z" },
  { card_id: "card-2", rating: "again", reviewed_at: "2026-01-01T00:00:00.000Z" },
  { card_id: "card-2", rating: "good", reviewed_at: "2026-01-02T00:00:00.000Z" },
  { card_id: "card-2", rating: "good", reviewed_at: "2026-01-05T00:00:00.000Z" },
];

const result = await optimizeWeights(rows);
if (result.weights.length !== 21) throw new Error(`Expected 21 weights, got ${result.weights.length}`);
if (result.cardCount !== 2) throw new Error(`Expected 2 cards, got ${result.cardCount}`);
console.log(JSON.stringify({ weights: result.weights.length, cardCount: result.cardCount }));
