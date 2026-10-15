// Recreate the fresh-page comparison directly from the archived bundles.
import fs from 'node:fs';
import {gunzipSync} from 'node:zlib';
import {execFileSync} from 'node:child_process';
const work='zig-out/direct-bytes-timing';
for(const [subject,artifact]of [['browser-tea-release','conduit-tea-baseline'],['direct-original','conduit-direct-baseline'],['browser-direct-release','conduit-direct-short-path-ids']]){
 fs.mkdirSync(`${work}/${subject}`,{recursive:true});
 fs.writeFileSync(`${work}/${subject}/_main.mjs`,gunzipSync(fs.readFileSync(`bench/direct-bytes/results/${artifact}.mjs.gz`)));
}
process.stdout.write(execFileSync('node',['bench/conduit/time.mjs',`--work=${work}`,'--baseline=direct-original','--samples=15',...(process.env.CHROME?[`--chrome=${process.env.CHROME}`]:[])],{maxBuffer:16<<20}));
