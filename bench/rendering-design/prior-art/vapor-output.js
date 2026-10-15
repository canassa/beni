import { child as _child, next as _next, on as _on, txt as _txt, toDisplayString as _toDisplayString, setText as _setText, renderEffect as _renderEffect, setInsertionState as _setInsertionState, createIf as _createIf, applyTextModel as _applyTextModel, template as _template } from 'vue';
const t0 = _template("<p>Too short", 2)
const t1 = _template("<div><button>Increment</button><output> </output><input>", 1)

export function render(_ctx) {
  const n6 = t1()
  const n0 = _child(n6)
  const n1 = _next(n0)
  const n2 = _next(n1)
  _on(n0, "click", () => (_ctx.count++))
  const x1 = _txt(n1)
  _renderEffect(() => _setText(x1, _toDisplayString(_ctx.count * 2)))
  _setInsertionState(n6, 3)
  const n3 = _createIf(() => (_ctx.name.length < 3), () => {
    const n5 = t0()
    return n5
  }, null, 33 /* TRUE_SINGLE_ROOT, TRUE_NO_SCOPE */)
  _applyTextModel(n2, () => (_ctx.name), _value => (_ctx.name = _value))
  return n6
}
