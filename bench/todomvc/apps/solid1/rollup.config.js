// solidjs/solid-todomvc's rollup.config.js (f48302376244513396de3e353e73ba136151b874)
// unchanged but for the input and output paths, chosen by ENTRY (full or
// parity): babel-preset-solid with @babel/preset-typescript, node-resolve,
// terser with its defaults, one IIFE.
import resolve from '@rollup/plugin-node-resolve';
import babel from '@rollup/plugin-babel';
import terser from '@rollup/plugin-terser';

const entry = process.env.ENTRY ?? 'full';

const plugins = [
	babel({
		extensions: [".js", ".ts", ".tsx"],
    exclude: 'node_modules/**',
    babelHelpers: "bundled",
		presets: ["solid", "@babel/preset-typescript"],
	}),
	resolve({ extensions: ['.js', '.ts', '.tsx'] })
];

if (process.env.production) {
	plugins.push(terser());
}

export default {
	input: `src/${entry}.tsx`,
	output: {
		file: `../../out/solid1-${entry}/bundle.js`,
		format: 'iife'
	},
	treeshake: {
		tryCatchDeoptimization: false
	},
	plugins
};
