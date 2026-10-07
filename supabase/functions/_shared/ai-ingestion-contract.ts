export type IngestionCard={fields:Record<string,string>;card_kind:'basic'|'reverse'|'cloze';card_ordinal:number;cloze_ordinal?:number|null};
export type IngestionNote={fields:Record<string,string>;cards:IngestionCard[]};
const fieldPairs={type:'array',items:{type:'object',additionalProperties:false,properties:{name:{type:'string'},value:{type:'string'}},required:['name','value']}};
export const ingestionSchema={type:'object',additionalProperties:false,properties:{notes:{type:'array',items:{type:'object',additionalProperties:false,properties:{fields:fieldPairs,cards:{type:'array',items:{type:'object',additionalProperties:false,properties:{fields:{type:'object',additionalProperties:false,properties:{Front:{type:'string'},Back:{type:'string'},Text:{type:['string','null']}},required:['Front','Back','Text']},card_kind:{type:'string',enum:['basic','reverse','cloze']},card_ordinal:{type:'integer',minimum:0},cloze_ordinal:{type:['integer','null']}},required:['fields','card_kind','card_ordinal','cloze_ordinal']}}},required:['fields','cards']}}},required:['notes']};
function normalizedFields(value:unknown):Record<string,string>{
 if(Array.isArray(value)){
  const pairs=value.map((entry)=>{if(!entry||typeof entry.name!=='string'||!entry.name.trim()||typeof entry.value!=='string')throw new Error('AI_INVALID_FIELDS');return [entry.name,entry.value] as [string,string];});
  if(new Set(pairs.map(([name])=>name)).size!==pairs.length)throw new Error('AI_DUPLICATE_FIELDS');
  return Object.fromEntries(pairs);
 }
 if(!value||typeof value!=='object')throw new Error('AI_INVALID_FIELDS');
 return Object.fromEntries(Object.entries(value).filter((entry):entry is [string,string]=>typeof entry[1]==='string'));
}
export function validateIngestionNotes(value:unknown):IngestionNote[]{
 if(!Array.isArray(value)||!value.length)throw new Error('AI_EMPTY_NOTES');
 return value.map((raw)=>{
  const fields=normalizedFields(raw.fields);if(!Object.keys(fields).length)throw new Error('AI_EMPTY_FIELDS');
  if(!Array.isArray(raw.cards)||!raw.cards.length)throw new Error('AI_EMPTY_CARDS');
  const ordinals=new Set<number>();
  const cards=raw.cards.map((card:any):IngestionCard=>{
   const cardFields=normalizedFields(card.fields);
   if(!cardFields.Front?.trim()||!cardFields.Back?.trim())throw new Error('AI_EMPTY_CARD_CONTENT');
   if(!['basic','reverse','cloze'].includes(card.card_kind)||!Number.isInteger(card.card_ordinal)||card.card_ordinal<0||ordinals.has(card.card_ordinal))throw new Error('AI_INVALID_CARD_ORDINAL');
   if(card.card_kind==='cloze'&&(!Number.isInteger(card.cloze_ordinal)||card.cloze_ordinal<1||!cardFields.Text?.includes('{{c')))throw new Error('AI_INVALID_CLOZE');
   ordinals.add(card.card_ordinal);return {...card,fields:cardFields};
  });return {fields,cards};
 });
}
