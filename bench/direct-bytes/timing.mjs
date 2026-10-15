// Recreate the fresh-page comparison directly from the archived bundles.
import fs from 'node:fs';
import {gunzipSync} from 'node:zlib';
import {execFileSync} from 'node:child_process';
const work='zig-out/direct-bytes-timing';
const variant=process.argv[2]??'short-path-ids';
if(!['short-path-ids','inline-group-records'].includes(variant))throw Error('Unknown timing variant');
for(const [subject,artifact]of [['browser-tea-release','conduit-tea-baseline'],['direct-original','conduit-direct-baseline'],['browser-direct-release',`conduit-direct-${variant}`]]){
 fs.mkdirSync(`${work}/${subject}`,{recursive:true});
 fs.writeFileSync(`${work}/${subject}/_main.mjs`,gunzipSync(fs.readFileSync(`bench/direct-bytes/results/${artifact}.mjs.gz`)));
}
const output=JSON.parse(execFileSync('node',['bench/conduit/time.mjs',`--work=${work}`,'--baseline=direct-original','--samples=15',...(process.env.CHROME?[`--chrome=${process.env.CHROME}`]:[])],{maxBuffer:16<<20,encoding:'utf8'}));
output.variant=variant;
output.subjectVariants={'browser-tea-release':'unchanged tea','direct-original':'unchanged direct','browser-direct-release':variant};
process.stdout.write(JSON.stringify(output,null,2)+'\n');
