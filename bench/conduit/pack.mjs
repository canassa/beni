// Preserve a profile directory as one lossless replayable archive.
// node bench/conduit/pack.mjs <directory> <summary.json> <output.json.gz>
import {readFileSync,readdirSync,writeFileSync} from 'node:fs';
import {gunzipSync,gzipSync} from 'node:zlib';
import {createHash} from 'node:crypto';
const [dir,summary,out]=process.argv.slice(2);
if(!out)throw new Error('Expected profile directory, summary JSON and output .json.gz');
const profiles=readdirSync(dir).filter(f=>f.endsWith('.json.gz')).sort().map(file=>JSON.parse(gunzipSync(readFileSync(`${dir}/${file}`))));
const data=Buffer.from(JSON.stringify({metadata:JSON.parse(readFileSync(summary,'utf8')),profiles}));
writeFileSync(out,gzipSync(data,{level:9}));
console.log(JSON.stringify({out,profiles:profiles.length,sha256:createHash('sha256').update(data).digest('hex')}));
