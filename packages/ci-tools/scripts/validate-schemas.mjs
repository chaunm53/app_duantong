import { promises as fs } from 'node:fs';
import path from 'node:path';
import fg from 'fast-glob';
import Ajv from 'ajv';
import addFormats from 'ajv-formats';
const ROOT=process.cwd();
const SERVICES_DIR=path.join(ROOT,'services');
const ajv=new Ajv({allErrors:true,strict:false});
addFormats(ajv);
function fail(m){console.error(`❌ ${m}`);process.exitCode=1;}
async function run(){const files=await fg(['**/contracts/json-schema/**/*.json'],{cwd:SERVICES_DIR,absolute:true});const ids=new Map();let c=0;for(const file of files){const raw=await fs.readFile(file,'utf8');let json;try{json=JSON.parse(raw);}catch(e){fail(`Invalid JSON in ${file}: ${e.message}`);continue;}if(!json.$schema) fail(`Missing $schema in ${file}`);if(!json.title) fail(`Missing title in ${file}`);if(json.$id){if(ids.has(json.$id)) fail(`Duplicate $id ${json.$id}`); else ids.set(json.$id,file);}try{ajv.compile(json);}catch(e){fail(`Schema compile error in ${file}: ${e.message}`);}c++;}if(process.exitCode){console.error('Schema validation completed with errors.');process.exit(process.exitCode);}else{console.log(`✅ Schemas OK: ${c} files validated.`);}}
run().catch(e=>{console.error(e);process.exit(1)});
