import {assertEquals,assertThrows} from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {ingestionSchema,validateIngestionNotes} from './ai-ingestion-contract.ts';
Deno.test('F15 every Structured Outputs object is closed and all properties are required',()=>{
 function walk(value:any){if(!value||typeof value!=='object')return;if(value.type==='object'){assertEquals(value.additionalProperties,false);assertEquals([...value.required].sort(),Object.keys(value.properties).sort());}for(const child of Object.values(value))walk(child);}
 walk(ingestionSchema);
});
const card={fields:{Front:'QA question',Back:'QA answer',Text:null},card_kind:'basic',card_ordinal:0,cloze_ordinal:null};
Deno.test('F15 normalize field pairs preserving schema names and rejecting duplicates',()=>{
 const rows=validateIngestionNotes([{fields:[{name:'Écologie',value:'QA content'},{name:'Context',value:'QA context'}],cards:[card]}]);
 assertEquals(rows[0]!.fields,{'Écologie':'QA content',Context:'QA context'});assertEquals(rows[0]!.cards[0]!.fields,{Front:'QA question',Back:'QA answer'});
 assertThrows(()=>validateIngestionNotes([{fields:[{name:'A',value:'1'},{name:'A',value:'2'}],cards:[card]}]));
});
Deno.test('F15 invalid or empty cards cannot become reviewable drafts',()=>{
 assertThrows(()=>validateIngestionNotes([{fields:[{name:'Q',value:'QA'}],cards:[card,card]}]));
 assertThrows(()=>validateIngestionNotes([{fields:[{name:'Q',value:'QA'}],cards:[{...card,fields:{Front:'',Back:'QA'}}]}]));
 assertThrows(()=>validateIngestionNotes([{fields:[{name:'Q',value:'QA'}],cards:[{...card,card_kind:'cloze',cloze_ordinal:1}]}]));
});
