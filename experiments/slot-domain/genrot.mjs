import fs from 'fs';
const n = +process.argv[2];
const ps = Array.from({ length: n }, (_, i) => `p${String(i).padStart(2, '0')}`);
let s = `rotate : Int, ${Array(n).fill('List Int').join(', ')} → List Int\nrotate k ${ps.join(' ')} =\n    if k == 0 then\n        p00\n    else\n        rotate (k - 1) ${[...ps.slice(1), ps[0]].join(' ')}\n\n\n`;
s += `seed : List Int\nseed = rotate 3 [ 7 ] ${Array(n - 1).fill('[]').join(' ')}\n\n\npub dest : List Int\ndest = List.push seed 2\n\n\npub local : Int → List Int\nlocal x = List.push (rotate 3 [ x ] ${Array(n - 1).fill('[]').join(' ')}) 2\n`;
fs.writeFileSync(`scale/Rotate${n}.beni`, s);
