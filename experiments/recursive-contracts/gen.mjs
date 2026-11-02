import fs from 'fs';
// gen.mjs copies <k> | fields <p>
const [mode, nArg] = process.argv.slice(2); const n = +nArg;
const big = process.argv[4] === 'big';
const out = [];
if (big) out.push('@ownership_summary_size(module, 50000000)', '');
out.push('type NColor\n    = Red\n    | Black\n');
const helpers = (s, p) => {
  const V = (pre) => Array.from({ length: p }, (_, i) => `${pre}${i}`);
  const pv = (pre) => V(pre).join(' '), w = (k) => Array(k).fill('_').join(' ');
  const T = `Tree${s}`, N = `Node${s}`, L = `Leaf${s}`;
  const vt = Array(p).fill('(List Int)').join(' ');
  return `
type ${T}
    = ${N} NColor Int ${vt} ${T} ${T}
    | ${L}


balance${s} : NColor, Int, ${Array(p).fill('List Int').join(', ')}, ${T}, ${T} → ${T}
balance${s} color key ${pv('v')} left right =
    case right of
        ${N} Red rK ${pv('rV')} rLeft rRight →
            case left of
                ${N} Red lK ${pv('lV')} lLeft lRight →
                    ${N} Red key ${pv('v')} (${N} Black lK ${pv('lV')} lLeft lRight) (${N} Black rK ${pv('rV')} rLeft rRight)

                _ →
                    ${N} color rK ${pv('rV')} (${N} Red key ${pv('v')} left rLeft) rRight

        _ →
            case left of
                ${N} Red lK ${pv('lV')} (${N} Red llK ${pv('llV')} llLeft llRight) lRight →
                    ${N} Red lK ${pv('lV')} (${N} Black llK ${pv('llV')} llLeft llRight) (${N} Black key ${pv('v')} lRight right)

                _ →
                    ${N} color key ${pv('v')} left right


removeMin${s} : ${T} → ${T}
removeMin${s} tree =
    case tree of
        ${N} color key ${pv('v')} ((${N} lColor _ ${w(p)} lLeft _) as left) right →
            case lColor of
                Black →
                    case lLeft of
                        ${N} Red _ ${w(p)} _ _ →
                            ${N} color key ${pv('v')} (removeMin${s} left) right

                        _ →
                            case moveRedLeft${s} tree of
                                ${N} nColor nKey ${pv('nV')} nLeft nRight →
                                    balance${s} nColor nKey ${pv('nV')} (removeMin${s} nLeft) nRight

                                ${L} →
                                    ${L}

                _ →
                    ${N} color key ${pv('v')} (removeMin${s} left) right

        _ →
            ${L}


moveRedLeft${s} : ${T} → ${T}
moveRedLeft${s} tree =
    case tree of
        ${N} _ k ${pv('v')} (${N} _ lK ${pv('lV')} lLeft lRight) (${N} _ rK ${pv('rV')} rLeft rRight) →
            case rLeft of
                ${N} Red rlK ${pv('rlV')} rlL rlR →
                    ${N} Red rlK ${pv('rlV')} (${N} Black k ${pv('v')} (${N} Red lK ${pv('lV')} lLeft lRight) rlL) (${N} Black rK ${pv('rV')} rlR rRight)

                _ →
                    ${N} Black k ${pv('v')} (${N} Red lK ${pv('lV')} lLeft lRight) (${N} Red rK ${pv('rV')} rLeft rRight)

        _ →
            tree
`; };
if (mode === 'copies') for (let i = 0; i < n; i++) out.push(helpers(String.fromCharCode(65 + i), 1));
else out.push(helpers('F', n));
fs.writeFileSync(`scale/${mode[0].toUpperCase() + mode.slice(1)}${n}${big ? "Big" : ""}.beni`, out.join('\n'));
