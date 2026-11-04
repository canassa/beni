export const value = (control) => { return control.value; };
export const setValue = (control, value) => { control.value = value; return null; };
export const disabled = (control) => { return control.disabled; };
export const selectionStart = (control) => { return control.selectionStart; };
export const selectionEnd = (control) => { return control.selectionEnd; };
export const selectionDirection = (control) => { return control.selectionDirection; };
export const setSelectionRange = (control, start, end, direction) => { control.setSelectionRange(start, end, direction); return null; };
export const toNode = (control) => control;
