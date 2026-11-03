// Loading every emitted module catches dangling exports in dependency files too.
import {readdirSync} from 'node:fs';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
for (const mode of ['development', 'release']) {
  const directory = resolve('out-' + mode);
  const library = await import(pathToFileURL(directory + '/Lib.mjs'));
  for (const file of readdirSync(directory, {recursive: true})) {
    if (file.endsWith('.mjs')) await import(pathToFileURL(directory + '/' + file));
  }
  console.log(mode + ' ' + JSON.stringify(Object.values(library).filter(value => typeof value === 'string')));
}
