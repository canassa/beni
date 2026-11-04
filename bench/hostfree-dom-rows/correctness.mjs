// Correctness through the real markup producer; no private runtime imports.
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { GlobalWindow as Window } from '../../tests/browser/happy-dom.mjs';
const window = new Window();
Object.assign(globalThis, { window, document: window.document, Node: window.Node });
const app = await import(pathToFileURL(resolve(process.argv[2] || 'zig-out/rows-dev', '_main.mjs')));
const cases = [[1,2,3], [3,1,4], [4], [], [9,8], [8,9]];
for (let turn=0; turn<cases.length*2; turn++) {
  const want = cases[turn % cases.length].map(String);
  for (const list of ['ul', 'ol'])
    assert.deepEqual([...document.querySelectorAll(list+' li')].map(n=>n.textContent), want);
  assert.deepEqual([...document.querySelectorAll('p')].map(n=>n.textContent), want.slice(0,1));
  document.querySelector('button').dispatchEvent(new window.MouseEvent('click', {bubbles:true}));
  app.flush();
}
console.log('12 keyed, positional and Show states verified through markup');
