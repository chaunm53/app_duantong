import { promises as fs } from 'node:fs';
import path from 'node:path';
import fg from 'fast-glob';
import { compile } from 'json-schema-to-typescript';
const ROOT=process.cwd();
const CONTRACTS_ROOT_DIR=path.join(ROOT,'../..','services');
const OUT_DIR=path.join(ROOT,'src','generated');
const INDEX_FILE=path.join(ROOT,'src','index.ts');
function toTypeName(t,f){if(t)return t.replace(/[^A-Za-z0-9_]/g,'');return f.replace(/\.json$/,'').replace(/[^A-Za-z0-9]/g,'_').replace(/(?:^|_)([a-z])/g,(_,c)=>c.toUpperCase());}
async function run(){await fs.mkdir(OUT_DIR,{recursive:true});const files=await fg(['**/contracts/json-schema/**/*.json'],{cwd:CONTRACTS_ROOT_DIR,absolute:true});const ex=[];for(const file of files){const json=JSON.parse(await fs.readFile(file,'utf8'));const name=toTypeName(json.title, path.basename(file));const ts=await compile(json,name,{bannerComment:'',style:{semi:true}});const out=path.basename(file).replace(/\.json$/,'.d.ts');await fs.writeFile(path.join(OUT_DIR,out),ts,'utf8');ex.push(`export * from './generated/${out.replace(/\.d\.ts$/,'')}';`);}await fs.writeFile(INDEX_FILE,ex.join('\n')+'\n','utf8');console.log('Generated',ex.length,'type files');}
run().catch(e=>{console.error(e);process.exit(1)});
