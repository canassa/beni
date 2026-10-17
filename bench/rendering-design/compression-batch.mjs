// Two independent byte strings at a time, with exactly the serial size options.
// The caller borrows one additional CPU slot while its own thread is parked.
import fs from 'node:fs';
import {brotliCompress,gzip,constants} from 'node:zlib';
import {promisify} from 'node:util';
const brotli=promisify(brotliCompress),gz=promisify(gzip);
const inputs=JSON.parse(fs.readFileSync(0,'utf8')),results=new Array(inputs.length);
let next=0;
await Promise.all(Array.from({length:Math.min(2,inputs.length)},async()=>{
 while(next<inputs.length){const index=next++,b=Buffer.from(inputs[index]);
  const br=await brotli(b,{params:{[constants.BROTLI_PARAM_QUALITY]:11,[constants.BROTLI_PARAM_SIZE_HINT]:b.length}});
  const zip=await gz(b,{level:9});
  results[index]={raw:b.length,brotli:br.length,gzip:zip.length};
 }
}));
process.stdout.write(JSON.stringify(results));
