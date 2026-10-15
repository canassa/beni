import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';

// Reconstruct the exact historical fixed stream, including its declaration-table
// ids and every byte of each program row. Extension tables must not renumber it.
export function historicalFixedPrefix(text, expectedSha256) {
  const limits = {fixture: 98, sync: 44, targeted: 348};
  const counts = {fixture: 0, sync: 0, targeted: 0};
  const tables = new Map(), originalTables = new Map();
  const hash = createHash('sha256');
  for (const line of text.split('\n')) {
    if (!line) continue;
    const row = JSON.parse(line);
    if (row[0] === 'table') {
      assert.equal(row.length, 3);
      assert(Number.isSafeInteger(row[1]) && !tables.has(row[1]));
      const header = JSON.stringify(row.slice(0, 2)).slice(0, -1) + ',';
      assert(line.startsWith(header) && line.endsWith(']'));
      tables.set(row[1], line.slice(header.length, -1));
      continue;
    }
    assert.equal(row[0], 'program');
    assert.equal(row.length, 14);
    const family = row[1], match = row[2].match(/^(fixture|sync|targeted)-(\d+)$/);
    assert(match && match[1] === family && Object.hasOwn(limits, family));
    if (Number(match[2]) >= limits[family]) continue;
    assert.equal(row[2], `${family}-${counts[family]++}`, 'historical fixed id/order changed');
    const declarations = tables.get(row[3]);
    assert.notEqual(declarations, undefined, 'historical declaration table missing');
    if (!originalTables.has(declarations)) {
      originalTables.set(declarations, originalTables.size);
      hash.update('["table",' + originalTables.get(declarations) + ',' + declarations + ']\n');
    }
    const header = JSON.stringify(row.slice(0, 4)).slice(0, -1) + ',';
    assert(line.startsWith(header));
    const original = [...row.slice(0, 3), originalTables.get(declarations)];
    // Preserve the remaining raw bytes, including integers beyond JS precision.
    hash.update(JSON.stringify(original).slice(0, -1) + ',' + line.slice(header.length) + '\n');
  }
  assert.deepEqual(counts, limits, 'historical fixed population changed');
  const sha256 = hash.digest('hex');
  assert.equal(sha256, expectedSha256, 'historical fixed source/verdict stream changed');
  return {programs: Object.values(counts).reduce((a, b) => a + b, 0), tables: originalTables.size, families: counts, sha256};
}
