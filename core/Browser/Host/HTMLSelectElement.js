export const value = (control) => { return control.value; };
export const setValue = (control, value) => { control.value = value; return null; };
export const selectedIndex = (control) => { return control.selectedIndex; };
export const setSelectedIndex = (control, value) => { control.selectedIndex = value; return null; };
export const disabled = (control) => { return control.disabled; };
export const toNode = (control) => control;
export const options = (control) => Array.from(control.options);
