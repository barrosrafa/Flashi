import initSqlJs from 'npm:sql.js@1.13.0/dist/sql-asm.js';
let engine:Promise<any>|undefined;
export async function openAnkiSqlite(bytes?:Uint8Array):Promise<AnkiSqlite>{
 engine??=initSqlJs();const SQL=await engine;return new AnkiSqlite(new SQL.Database(bytes));
}
/** Thin adapter over a real SQLite engine; no synthetic rows or fallback data. */
class AnkiSqlite{
 constructor(private readonly db:any){}
 selectValue(sql:string):unknown{const statement=this.db.prepare(sql);try{return statement.step()?statement.get()[0]:undefined;}finally{statement.free();}}
 exec(input:string|{sql:string;bind?:unknown[];rowMode?:string;returnValue?:string}):any{
  if(typeof input==='string'){this.db.run(input);return;}
  if(input.returnValue!=='resultRows'){this.db.run(input.sql,input.bind??[]);return;}
  const statement=this.db.prepare(input.sql);const rows:Record<string,unknown>[]=[];
  try{if(input.bind)statement.bind(input.bind);while(statement.step())rows.push(statement.getAsObject());return rows;}finally{statement.free();}
 }
 export():Uint8Array{return this.db.export();}
 close():void{this.db.close();}
}
