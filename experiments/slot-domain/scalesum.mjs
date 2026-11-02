import fs from 'fs';
const files = process.argv.slice(2);
console.log('| file | time | max RSS | module total | removeMin* total (growth) | per-walk (settled) | balance* | slots | arrivals | relations | deliveries | substitutions | validation | peak bytes (max decl) | sel size (removeMin) |');
for (const f of files) {
  const out = fs.readFileSync(`final/scale/${f}.out`, 'utf8'); const tm = fs.readFileSync(`final/scale/${f}.time`, 'utf8').trim();
  let tot = 0, rm = 0, rmg = 0, bal = 0, slots = 0, arr = 0, rel = 0, del = 0, sub = 0, val = 0, peak = 0, walk = 0, sel = 0;
  for (const l of out.split('\n')) {
    const m = /slotacct (\S+): source \d+, total (\d+), growth (\d+).*?validation (\d+), slots (\d+), arrivals (\d+), relations (\d+).*?deliveries (\d+), substitutions (\d+).*?peak bytes (\d+).*walks \{ ([\d, ]+) \}/.exec(l);
    if (m) {
      tot += +m[2]; slots += +m[5]; arr += +m[6]; rel += +m[7]; del += +m[8]; sub += +m[9]; val += +m[4]; peak = Math.max(peak, +m[10]);
      if (m[1].startsWith('removeMin')) { rm += +m[2]; rmg += +m[3]; const w = m[11].split(',').map(Number); walk = Math.max(walk, w[w.length - 1]); }
      if (m[1].startsWith('balance')) bal += +m[2];
    }
    const c = /contract removeMin\S*: .*nondup ⇐ sel (.*)$/.exec(l); if (c) sel = Math.max(sel, (c[1].match(/,/g) || []).length + (c[1].match(/π/g) || []).length);
  }
  console.log(`| ${f} | ${tm.split(' s ')[0]} s | ${Math.round(+tm.split(' s ')[1].split(' ')[0] / 1024)} MB | ${tot} | ${rm} (${rmg}) | ${walk} | ${bal} | ${slots} | ${arr} | ${rel} | ${del} | ${sub} | ${val} | ${peak} | ${sel} |`);
}
