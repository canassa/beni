import { template as _$template } from "@solidjs/web";
import { insert as _$insert } from "@solidjs/web";
import { createComponent as _$createComponent } from "@solidjs/web";
import { effect as _$effect } from "@solidjs/web";
import { delegateEvents as _$delegateEvents } from "@solidjs/web";
var _tmpl$ = /* @__PURE__ */ _$template(`<p>Too short`);
var _tmpl$2 = /* @__PURE__ */ _$template(`<div><button>Increment</button><output></output><input>`);
import { createSignal, Show } from "solid-js";
export default function Shared() {
	const [count, setCount] = createSignal(0), [name, setName] = createSignal("");
	var _el$ = _tmpl$2();
	var _el$2 = _el$.firstChild;
	var _el$3 = _el$2.nextSibling;
	var _el$4 = _el$3.nextSibling;
	_el$2._$$click = () => setCount((n) => n + 1);
	_$insert(_el$3, () => {
		return count() * 2;
	});
	_el$4._$$input = (e) => setName(e.target.value);
	_$insert(_el$, _$createComponent(Show, {
		get when() {
			return name().length < 3;
		},
		get children() {
			return _tmpl$();
		}
	}), null);
	_$effect(() => name(), (_v$) => {
		_el$4.value = _v$ ?? "";
	});
	return _el$;
}
_$delegateEvents(["click", "input"]);
