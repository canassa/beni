import fs from 'fs';
const rows = [];
for (const f of fs.readdirSync('scale').filter(f => f.endsWith('.time')).sort()) {
  const [n, s] = f.replace('.time', '').split('.');
  const [t, rssLine, rcLine] = fs.readFileSync('scale/' + f, 'utf8').trim().split('\n');
  const [sec, rss] = t.split(' ');
  const out = fs.existsSync(`scale/${n}.${s}.out`) ? fs.readFileSync(`scale/${n}.${s}.out`, 'utf8') : '';
  let total = 0, growth = 0, limits = 0, walks = 0, slots = 0, origins = 0, alpha = 0, tok = 0, val = 0, rounds = 0, ports = 0, w2 = [];
  for (const l of out.split('\n')) {
    let m = l.match(/^  account \S+: .*growth (\d+) of \d+, total (\d+)/); if (m) { growth += +m[1]; total += +m[2]; const w = l.match(/walks (\d+)/); if (w) walks += +w[1]; }
    if (/^  limit /.test(l)) limits++;
    m = l.match(/^  contract (\S+): stage \d+, rounds (\d+), slots (\d+), slot cells \d+, origins (\d+), unknown \d+, alpha (\d+), port nodes (\d+), tokens \d+, token ops (\d+), token rounds \d+, validation ops (\d+).*walk2 growth (\d+)/);
    if (m) { rounds = Math.max(rounds, +m[2]); slots += +m[3]; origins += +m[4]; alpha += +m[5]; ports += +m[6]; tok += +m[7]; val += +m[8]; if (/removeMin/.test(m[1])) w2.push(+m[9]); }
  }
  rows.push({ n, s, sec: +sec, rssMB: Math.round(rss / 1024), rc: rcLine, limits, total, growth, walks, maxRounds: rounds, slots, origins, alpha, ports, tok, val, w2: w2.join('/') });
}
console.table(rows);
