import { Browser$Host$Set$make, Browser$Host$Set$add, Browser$Host$Set$has, Browser$Host$Set$size, Browser$Host$Set$clear, Browser$Host$Set$each } from "./_core/Browser/Host/Set.mjs";
import { Browser$Host$Array$eachView, Browser$Host$Array$each } from "./_core/Browser/Host/Array.mjs";
import { Js$optNone } from "./_core/Js.mjs";
import { Browser$Host$Event$kind, Browser$Host$Event$isTrusted, Browser$Host$Event$bubbles, Browser$Host$Event$cancelBubble, Browser$Host$Event$stopPropagation, Browser$Host$Event$target, Browser$Host$Event$rendererEarlyListeners, Browser$Host$Event$rendererEarlyAppend, Browser$Host$Event$rendererEarlySize, Browser$Host$Event$rendererEarlyKindAt, Browser$Host$Event$rendererEarlyHandlerAt, Browser$Host$Event$rendererTarget, Browser$Host$Event$rendererCurrentTarget, Browser$Host$Event$rendererClearCurrentTarget, Browser$Host$Event$rendererTakeEarly, Browser$Host$Event$rendererEarlyEvent, Browser$Host$Event$rendererEarlyTarget, Browser$Host$Event$rendererEarlyRemember, Browser$Host$Event$rendererEarlyValue, Browser$Host$Event$rendererEarlyChecked, Browser$Host$Event$rendererEarlySelectedIndex } from "./_core/Browser/Host/Event.mjs";
import { Browser$Host$EventTarget$asNode, Browser$Host$EventTarget$asElement, Browser$Host$EventTarget$asInput, Browser$Host$EventTarget$asTextArea, Browser$Host$EventTarget$asSelect, Browser$Host$EventTarget$asOption, Browser$Host$EventTarget$asForm } from "./_core/Browser/Host/EventTarget.mjs";
import { Browser$Host$Node$contains, Browser$Host$Node$rendererDisabled, Browser$Host$Node$rendererTag, Browser$Host$Node$rendererKind, Browser$Host$Node$rendererName, Browser$Host$Node$rendererFocused, Browser$Host$Node$rendererValue, Browser$Host$Node$rendererSetValue, Browser$Host$Node$rendererChecked, Browser$Host$Node$rendererSetChecked, Browser$Host$Node$rendererSelected, Browser$Host$Node$rendererSetSelected, Browser$Host$Node$rendererSelectedIndex, Browser$Host$Node$rendererSetSelectedIndex, Browser$Host$Node$rendererSelectionStart, Browser$Host$Node$rendererSelectionEnd, Browser$Host$Node$rendererSelectionDirection, Browser$Host$Node$rendererSetSelectionRange, Browser$Host$Node$rendererOptions, Browser$Host$Node$rendererElements, Browser$Host$Node$rendererEdits, Browser$Host$Node$rendererSetEdits } from "./_core/Browser/Host/Node.mjs";
import { Browser$Host$Element$localName } from "./_core/Browser/Host/Element.mjs";
import { Browser$Host$HTMLInputElement$value, Browser$Host$HTMLInputElement$setValue, Browser$Host$HTMLInputElement$checked, Browser$Host$HTMLInputElement$setChecked, Browser$Host$HTMLInputElement$disabled, Browser$Host$HTMLInputElement$kind, Browser$Host$HTMLInputElement$name, Browser$Host$HTMLInputElement$selectionStart, Browser$Host$HTMLInputElement$selectionEnd, Browser$Host$HTMLInputElement$selectionDirection, Browser$Host$HTMLInputElement$setSelectionRange, Browser$Host$HTMLInputElement$toNode } from "./_core/Browser/Host/HTMLInputElement.mjs";
import { Browser$Host$HTMLTextAreaElement$value, Browser$Host$HTMLTextAreaElement$setValue, Browser$Host$HTMLTextAreaElement$disabled, Browser$Host$HTMLTextAreaElement$selectionStart, Browser$Host$HTMLTextAreaElement$selectionEnd, Browser$Host$HTMLTextAreaElement$selectionDirection, Browser$Host$HTMLTextAreaElement$setSelectionRange, Browser$Host$HTMLTextAreaElement$toNode } from "./_core/Browser/Host/HTMLTextAreaElement.mjs";
import { Browser$Host$HTMLSelectElement$value, Browser$Host$HTMLSelectElement$setValue, Browser$Host$HTMLSelectElement$selectedIndex, Browser$Host$HTMLSelectElement$setSelectedIndex, Browser$Host$HTMLSelectElement$disabled, Browser$Host$HTMLSelectElement$toNode, Browser$Host$HTMLSelectElement$options } from "./_core/Browser/Host/HTMLSelectElement.mjs";
import { Browser$Host$HTMLOptionElement$selected, Browser$Host$HTMLOptionElement$setSelected, Browser$Host$HTMLOptionElement$toNode } from "./_core/Browser/Host/HTMLOptionElement.mjs";
import { Browser$Host$HTMLFormElement$toNode, Browser$Host$HTMLFormElement$elements } from "./_core/Browser/Host/HTMLFormElement.mjs";
import { Browser$Host$Document$getElementsByName, Browser$Host$Document$activeElement, Browser$Host$Document$controls, Browser$Host$Document$rendererNamed, Browser$Host$Document$rendererControls } from "./_core/Browser/Host/Document.mjs";
import { Browser$Host$Events$capture } from "./_core/Browser/Host/Events.mjs";
const NativeEvents$rendererearlylisteners = (p0$1) => [];
const NativeEvents$rendererearlyappend = (p0$1, p1$2, p2$3) => {
  p0$1.push(p1$2, p2$3);
  return null;
};
const NativeEvents$rendererearlysize = (p0$1) => p0$1.length / 2;
const NativeEvents$rendererearlykindat = (p0$1, p1$2) => {
  if (p1$2 !== p1$2 >>> 0 || p1$2 * 2 >= p0$1.length) {
    throw new globalThis.RangeError("beni: early listener index out of bounds");
  }
  return p0$1[p1$2 * 2];
};
const NativeEvents$rendererearlyhandlerat = (p0$1, p1$2) => {
  if (p1$2 !== p1$2 >>> 0 || p1$2 * 2 + 1 >= p0$1.length) {
    throw new globalThis.RangeError("beni: early listener index out of bounds");
  }
  return p0$1[p1$2 * 2 + 1];
};
const NativeEvents$setmake = (p0$1) => Browser$Host$Set$make(p0$1);
const NativeEvents$setadd = (p0$1, p1$2) => Browser$Host$Set$add(p0$1, p1$2);
const NativeEvents$sethas = (p0$1, p1$2) => Browser$Host$Set$has(p0$1, p1$2);
const NativeEvents$setsize = (p0$1) => Browser$Host$Set$size(p0$1);
const NativeEvents$setclear = (p0$1) => Browser$Host$Set$clear(p0$1);
const NativeEvents$seteach = (p0$1, p1$2) => Browser$Host$Set$each(p0$1, p1$2);
const NativeEvents$arrayeachview = (p0$1, p1$2) => Browser$Host$Array$eachView(p0$1, p1$2);
const NativeEvents$renderereventtarget = (p0$1) => {
  const $t$1 = p0$1.target;
  return $t$1 instanceof globalThis.Node ? $t$1 : Js$optNone;
};
const NativeEvents$renderernodedisabled = (p0$1) => !!p0$1.disabled;
const NativeEvents$renderernodetag = (p0$1) => p0$1.localName || "";
const NativeEvents$renderernodekind = (p0$1) => p0$1.type || "";
const NativeEvents$renderernodename = (p0$1) => p0$1.name || "";
const NativeEvents$renderernodefocused = (p0$1) => p0$1 === globalThis.document.activeElement;
const NativeEvents$renderercontrolvalue = (p0$1) => p0$1.value;
const NativeEvents$renderercontrolvalueset = (p0$1, p1$2) => {
  p0$1.value = p1$2;
  return null;
};
const NativeEvents$renderercontrolchecked = (p0$1) => p0$1.checked;
const NativeEvents$renderercontrolcheckedset = (p0$1, p1$2) => {
  p0$1.checked = p1$2;
  return null;
};
const NativeEvents$renderercontrolselected = (p0$1) => p0$1.selected;
const NativeEvents$renderercontrolselectedset = (p0$1, p1$2) => {
  p0$1.selected = p1$2;
  return null;
};
const NativeEvents$renderercontrolselectedIndex = (p0$1) => p0$1.selectedIndex;
const NativeEvents$renderercontrolselectedIndexset = (p0$1, p1$2) => {
  p0$1.selectedIndex = p1$2;
  return null;
};
const NativeEvents$rendererselectionStart = (p0$1) => {
  const $t$1 = p0$1.selectionStart;
  return $t$1 === undefined || $t$1 === null ? Js$optNone : $t$1;
};
const NativeEvents$rendererselectionEnd = (p0$1) => {
  const $t$1 = p0$1.selectionEnd;
  return $t$1 === undefined || $t$1 === null ? Js$optNone : $t$1;
};
const NativeEvents$rendererselectionDirection = (p0$1) => p0$1.selectionDirection;
const NativeEvents$rendererselectionset = (p0$1, p1$2, p2$3, p3$4) => {
  p0$1.setSelectionRange(p1$2, p2$3, p3$4);
  return null;
};
const NativeEvents$renderernodeoptions = (p0$1) => p0$1.options;
const NativeEvents$renderernodeelements = (p0$1) => p0$1.elements;
const NativeEvents$rendererdocumentnamed = (p0$1) => globalThis.document.getElementsByName(p0$1);
const NativeEvents$rendererdocumentcontrols = (p0$1) => globalThis.document.querySelectorAll("input,select,textarea,option");
const NativeEvents$renderernodeedits = (p0$1) => {
  const $t$1 = p0$1.$$e;
  return $t$1 === undefined ? Js$optNone : $t$1;
};
const NativeEvents$renderernodeeditsset = (p0$1, p1$2) => {
  p0$1.$$e = p1$2;
  return null;
};
const NativeEvents$arrayeach = (p0$1, p1$2) => Browser$Host$Array$each(p0$1, p1$2);
const NativeEvents$eventtype = (p0$1) => Browser$Host$Event$kind(p0$1);
const NativeEvents$eventisTrusted = (p0$1) => Browser$Host$Event$isTrusted(p0$1);
const NativeEvents$eventbubbles = (p0$1) => Browser$Host$Event$bubbles(p0$1);
const NativeEvents$eventcancelBubble = (p0$1) => Browser$Host$Event$cancelBubble(p0$1);
const NativeEvents$eventstop = (p0$1) => Browser$Host$Event$stopPropagation(p0$1);
const NativeEvents$eventtarget = (p0$1) => Browser$Host$Event$target(p0$1);
const NativeEvents$targetnode = (p0$1) => Browser$Host$EventTarget$asNode(p0$1);
const NativeEvents$nodeelement = (p0$1) => Browser$Host$EventTarget$asElement(p0$1);
const NativeEvents$nodecontains = (p0$1, p1$2) => Browser$Host$Node$contains(p0$1, p1$2);
const NativeEvents$elementlocal = (p0$1) => Browser$Host$Element$localName(p0$1);
const NativeEvents$elementasinput = (p0$1) => Browser$Host$EventTarget$asInput(p0$1);
const NativeEvents$inputvalue = (p0$1) => Browser$Host$HTMLInputElement$value(p0$1);
const NativeEvents$inputvalueset = (p0$1, p1$2) => Browser$Host$HTMLInputElement$setValue(p0$1, p1$2);
const NativeEvents$inputchecked = (p0$1) => Browser$Host$HTMLInputElement$checked(p0$1);
const NativeEvents$inputcheckedset = (p0$1, p1$2) => Browser$Host$HTMLInputElement$setChecked(p0$1, p1$2);
const NativeEvents$inputdisabled = (p0$1) => Browser$Host$HTMLInputElement$disabled(p0$1);
const NativeEvents$inputtype = (p0$1) => Browser$Host$HTMLInputElement$kind(p0$1);
const NativeEvents$inputname = (p0$1) => Browser$Host$HTMLInputElement$name(p0$1);
const NativeEvents$inputselectionStart = (p0$1) => Browser$Host$HTMLInputElement$selectionStart(p0$1);
const NativeEvents$inputselectionEnd = (p0$1) => Browser$Host$HTMLInputElement$selectionEnd(p0$1);
const NativeEvents$inputselectionDirection = (p0$1) => Browser$Host$HTMLInputElement$selectionDirection(p0$1);
const NativeEvents$inputselectionset = (p0$1, p1$2, p2$3, p3$4) => Browser$Host$HTMLInputElement$setSelectionRange(p0$1, p1$2, p2$3, p3$4);
const NativeEvents$inputnode = (p0$1) => Browser$Host$HTMLInputElement$toNode(p0$1);
const NativeEvents$elementastextarea = (p0$1) => Browser$Host$EventTarget$asTextArea(p0$1);
const NativeEvents$textareavalue = (p0$1) => Browser$Host$HTMLTextAreaElement$value(p0$1);
const NativeEvents$textareavalueset = (p0$1, p1$2) => Browser$Host$HTMLTextAreaElement$setValue(p0$1, p1$2);
const NativeEvents$textareadisabled = (p0$1) => Browser$Host$HTMLTextAreaElement$disabled(p0$1);
const NativeEvents$textareaselectionStart = (p0$1) => Browser$Host$HTMLTextAreaElement$selectionStart(p0$1);
const NativeEvents$textareaselectionEnd = (p0$1) => Browser$Host$HTMLTextAreaElement$selectionEnd(p0$1);
const NativeEvents$textareaselectionDirection = (p0$1) => Browser$Host$HTMLTextAreaElement$selectionDirection(p0$1);
const NativeEvents$textareaselectionset = (p0$1, p1$2, p2$3, p3$4) => Browser$Host$HTMLTextAreaElement$setSelectionRange(p0$1, p1$2, p2$3, p3$4);
const NativeEvents$textareanode = (p0$1) => Browser$Host$HTMLTextAreaElement$toNode(p0$1);
const NativeEvents$elementasselect = (p0$1) => Browser$Host$EventTarget$asSelect(p0$1);
const NativeEvents$selectvalue = (p0$1) => Browser$Host$HTMLSelectElement$value(p0$1);
const NativeEvents$selectvalueset = (p0$1, p1$2) => Browser$Host$HTMLSelectElement$setValue(p0$1, p1$2);
const NativeEvents$selectselectedIndex = (p0$1) => Browser$Host$HTMLSelectElement$selectedIndex(p0$1);
const NativeEvents$selectselectedIndexset = (p0$1, p1$2) => Browser$Host$HTMLSelectElement$setSelectedIndex(p0$1, p1$2);
const NativeEvents$selectdisabled = (p0$1) => Browser$Host$HTMLSelectElement$disabled(p0$1);
const NativeEvents$selectnode = (p0$1) => Browser$Host$HTMLSelectElement$toNode(p0$1);
const NativeEvents$elementasoption = (p0$1) => Browser$Host$EventTarget$asOption(p0$1);
const NativeEvents$optionselected = (p0$1) => Browser$Host$HTMLOptionElement$selected(p0$1);
const NativeEvents$optionselectedset = (p0$1, p1$2) => Browser$Host$HTMLOptionElement$setSelected(p0$1, p1$2);
const NativeEvents$optionnode = (p0$1) => Browser$Host$HTMLOptionElement$toNode(p0$1);
const NativeEvents$elementasform = (p0$1) => Browser$Host$EventTarget$asForm(p0$1);
const NativeEvents$formnode = (p0$1) => Browser$Host$HTMLFormElement$toNode(p0$1);
const NativeEvents$selectoptions = (p0$1) => Browser$Host$HTMLSelectElement$options(p0$1);
const NativeEvents$formelements = (p0$1) => Browser$Host$HTMLFormElement$elements(p0$1);
const NativeEvents$documentnamed = (p0$1) => Browser$Host$Document$getElementsByName(p0$1);
const NativeEvents$documentactive = (p0$1) => Browser$Host$Document$activeElement(p0$1);
const NativeEvents$documentcontrols = (p0$1) => Browser$Host$Document$controls(p0$1);
const NativeEvents$eventcapture = (p0$1, p1$2, p2$3) => Browser$Host$Events$capture(p0$1, p1$2, p2$3);
const NativeEvents$renderercurrent = (p0$1, p1$2) => {
  globalThis.Object.defineProperty(p0$1, "currentTarget", { configurable: true, get: () => p1$2.v === Js$optNone ? null : p1$2.v });
  return null;
};
const NativeEvents$renderercurrentclear = (p0$1) => {
  globalThis.Reflect.deleteProperty(p0$1, "currentTarget");
  return null;
};
const NativeEvents$rendererearlytake = (p0$1) => {
  const $t$1 = globalThis.$beni;
  if (!($t$1 === undefined)) {
    globalThis.$beni = undefined;
  }
  return $t$1 === undefined ? [] : $t$1();
};
const NativeEvents$rendererearlyevent = (p0$1) => p0$1[0];
const NativeEvents$rendererearlytarget = (p0$1) => p0$1[0].target;
const NativeEvents$rendererearlyremember = (p0$1) => {
  p0$1.push(p0$1[0].target.value, p0$1[0].target.checked, p0$1[0].target.selectedIndex);
  return null;
};
const NativeEvents$rendererearlyvalue = (p0$1, p1$2) => {
  const $t$1 = p0$1[p1$2];
  return $t$1 === undefined ? Js$optNone : $t$1;
};
const NativeEvents$rendererearlychecked = (p0$1, p1$2) => {
  const $t$1 = p0$1[p1$2 + 1];
  return $t$1 === undefined ? Js$optNone : $t$1;
};
const NativeEvents$rendererearlyselectedindex = (p0$1, p1$2) => {
  const $t$1 = p0$1[p1$2 + 2];
  return $t$1 === undefined ? Js$optNone : $t$1;
};
const NativeEvents$functions = { arrayeach: Browser$Host$Array$each, arrayeachview: Browser$Host$Array$eachView, documentactive: Browser$Host$Document$activeElement, documentcontrols: Browser$Host$Document$controls, documentnamed: Browser$Host$Document$getElementsByName, elementasform: Browser$Host$EventTarget$asForm, elementasinput: Browser$Host$EventTarget$asInput, elementasoption: Browser$Host$EventTarget$asOption, elementasselect: Browser$Host$EventTarget$asSelect, elementastextarea: Browser$Host$EventTarget$asTextArea, elementlocal: Browser$Host$Element$localName, eventbubbles: Browser$Host$Event$bubbles, eventcancelBubble: Browser$Host$Event$cancelBubble, eventcapture: Browser$Host$Events$capture, eventisTrusted: Browser$Host$Event$isTrusted, eventstop: Browser$Host$Event$stopPropagation, eventtarget: Browser$Host$Event$target, eventtype: Browser$Host$Event$kind, formelements: Browser$Host$HTMLFormElement$elements, formnode: Browser$Host$HTMLFormElement$toNode, inputchecked: Browser$Host$HTMLInputElement$checked, inputcheckedset: Browser$Host$HTMLInputElement$setChecked, inputdisabled: Browser$Host$HTMLInputElement$disabled, inputname: Browser$Host$HTMLInputElement$name, inputnode: Browser$Host$HTMLInputElement$toNode, inputselectionDirection: Browser$Host$HTMLInputElement$selectionDirection, inputselectionEnd: Browser$Host$HTMLInputElement$selectionEnd, inputselectionStart: Browser$Host$HTMLInputElement$selectionStart, inputselectionset: Browser$Host$HTMLInputElement$setSelectionRange, inputtype: Browser$Host$HTMLInputElement$kind, inputvalue: Browser$Host$HTMLInputElement$value, inputvalueset: Browser$Host$HTMLInputElement$setValue, nodecontains: Browser$Host$Node$contains, nodeelement: Browser$Host$EventTarget$asElement, optionnode: Browser$Host$HTMLOptionElement$toNode, optionselected: Browser$Host$HTMLOptionElement$selected, optionselectedset: Browser$Host$HTMLOptionElement$setSelected, renderercontrolchecked: Browser$Host$Node$rendererChecked, renderercontrolcheckedset: Browser$Host$Node$rendererSetChecked, renderercontrolselected: Browser$Host$Node$rendererSelected, renderercontrolselectedIndex: Browser$Host$Node$rendererSelectedIndex, renderercontrolselectedIndexset: Browser$Host$Node$rendererSetSelectedIndex, renderercontrolselectedset: Browser$Host$Node$rendererSetSelected, renderercontrolvalue: Browser$Host$Node$rendererValue, renderercontrolvalueset: Browser$Host$Node$rendererSetValue, renderercurrent: Browser$Host$Event$rendererCurrentTarget, renderercurrentclear: Browser$Host$Event$rendererClearCurrentTarget, rendererdocumentcontrols: Browser$Host$Document$rendererControls, rendererdocumentnamed: Browser$Host$Document$rendererNamed, rendererearlyappend: Browser$Host$Event$rendererEarlyAppend, rendererearlychecked: Browser$Host$Event$rendererEarlyChecked, rendererearlyevent: Browser$Host$Event$rendererEarlyEvent, rendererearlyhandlerat: Browser$Host$Event$rendererEarlyHandlerAt, rendererearlykindat: Browser$Host$Event$rendererEarlyKindAt, rendererearlylisteners: Browser$Host$Event$rendererEarlyListeners, rendererearlyremember: Browser$Host$Event$rendererEarlyRemember, rendererearlyselectedindex: Browser$Host$Event$rendererEarlySelectedIndex, rendererearlysize: Browser$Host$Event$rendererEarlySize, rendererearlytake: Browser$Host$Event$rendererTakeEarly, rendererearlytarget: Browser$Host$Event$rendererEarlyTarget, rendererearlyvalue: Browser$Host$Event$rendererEarlyValue, renderereventtarget: Browser$Host$Event$rendererTarget, renderernodedisabled: Browser$Host$Node$rendererDisabled, renderernodeedits: Browser$Host$Node$rendererEdits, renderernodeeditsset: Browser$Host$Node$rendererSetEdits, renderernodeelements: Browser$Host$Node$rendererElements, renderernodefocused: Browser$Host$Node$rendererFocused, renderernodekind: Browser$Host$Node$rendererKind, renderernodename: Browser$Host$Node$rendererName, renderernodeoptions: Browser$Host$Node$rendererOptions, renderernodetag: Browser$Host$Node$rendererTag, rendererselectionDirection: Browser$Host$Node$rendererSelectionDirection, rendererselectionEnd: Browser$Host$Node$rendererSelectionEnd, rendererselectionStart: Browser$Host$Node$rendererSelectionStart, rendererselectionset: Browser$Host$Node$rendererSetSelectionRange, selectdisabled: Browser$Host$HTMLSelectElement$disabled, selectnode: Browser$Host$HTMLSelectElement$toNode, selectoptions: Browser$Host$HTMLSelectElement$options, selectselectedIndex: Browser$Host$HTMLSelectElement$selectedIndex, selectselectedIndexset: Browser$Host$HTMLSelectElement$setSelectedIndex, selectvalue: Browser$Host$HTMLSelectElement$value, selectvalueset: Browser$Host$HTMLSelectElement$setValue, setadd: Browser$Host$Set$add, setclear: Browser$Host$Set$clear, seteach: Browser$Host$Set$each, sethas: Browser$Host$Set$has, setmake: Browser$Host$Set$make, setsize: Browser$Host$Set$size, targetnode: Browser$Host$EventTarget$asNode, textareadisabled: Browser$Host$HTMLTextAreaElement$disabled, textareanode: Browser$Host$HTMLTextAreaElement$toNode, textareaselectionDirection: Browser$Host$HTMLTextAreaElement$selectionDirection, textareaselectionEnd: Browser$Host$HTMLTextAreaElement$selectionEnd, textareaselectionStart: Browser$Host$HTMLTextAreaElement$selectionStart, textareaselectionset: Browser$Host$HTMLTextAreaElement$setSelectionRange, textareavalue: Browser$Host$HTMLTextAreaElement$value, textareavalueset: Browser$Host$HTMLTextAreaElement$setValue };
export { NativeEvents$rendererearlylisteners, NativeEvents$rendererearlyappend, NativeEvents$rendererearlysize, NativeEvents$rendererearlykindat, NativeEvents$rendererearlyhandlerat, NativeEvents$setmake, NativeEvents$setadd, NativeEvents$sethas, NativeEvents$setsize, NativeEvents$setclear, NativeEvents$seteach, NativeEvents$arrayeachview, NativeEvents$renderereventtarget, NativeEvents$renderernodedisabled, NativeEvents$renderernodetag, NativeEvents$renderernodekind, NativeEvents$renderernodename, NativeEvents$renderernodefocused, NativeEvents$renderercontrolvalue, NativeEvents$renderercontrolvalueset, NativeEvents$renderercontrolchecked, NativeEvents$renderercontrolcheckedset, NativeEvents$renderercontrolselected, NativeEvents$renderercontrolselectedset, NativeEvents$renderercontrolselectedIndex, NativeEvents$renderercontrolselectedIndexset, NativeEvents$rendererselectionStart, NativeEvents$rendererselectionEnd, NativeEvents$rendererselectionDirection, NativeEvents$rendererselectionset, NativeEvents$renderernodeoptions, NativeEvents$renderernodeelements, NativeEvents$rendererdocumentnamed, NativeEvents$rendererdocumentcontrols, NativeEvents$renderernodeedits, NativeEvents$renderernodeeditsset, NativeEvents$arrayeach, NativeEvents$eventtype, NativeEvents$eventisTrusted, NativeEvents$eventbubbles, NativeEvents$eventcancelBubble, NativeEvents$eventstop, NativeEvents$eventtarget, NativeEvents$targetnode, NativeEvents$nodeelement, NativeEvents$nodecontains, NativeEvents$elementlocal, NativeEvents$elementasinput, NativeEvents$inputvalue, NativeEvents$inputvalueset, NativeEvents$inputchecked, NativeEvents$inputcheckedset, NativeEvents$inputdisabled, NativeEvents$inputtype, NativeEvents$inputname, NativeEvents$inputselectionStart, NativeEvents$inputselectionEnd, NativeEvents$inputselectionDirection, NativeEvents$inputselectionset, NativeEvents$inputnode, NativeEvents$elementastextarea, NativeEvents$textareavalue, NativeEvents$textareavalueset, NativeEvents$textareadisabled, NativeEvents$textareaselectionStart, NativeEvents$textareaselectionEnd, NativeEvents$textareaselectionDirection, NativeEvents$textareaselectionset, NativeEvents$textareanode, NativeEvents$elementasselect, NativeEvents$selectvalue, NativeEvents$selectvalueset, NativeEvents$selectselectedIndex, NativeEvents$selectselectedIndexset, NativeEvents$selectdisabled, NativeEvents$selectnode, NativeEvents$elementasoption, NativeEvents$optionselected, NativeEvents$optionselectedset, NativeEvents$optionnode, NativeEvents$elementasform, NativeEvents$formnode, NativeEvents$selectoptions, NativeEvents$formelements, NativeEvents$documentnamed, NativeEvents$documentactive, NativeEvents$documentcontrols, NativeEvents$eventcapture, NativeEvents$renderercurrent, NativeEvents$renderercurrentclear, NativeEvents$rendererearlytake, NativeEvents$rendererearlyevent, NativeEvents$rendererearlytarget, NativeEvents$rendererearlyremember, NativeEvents$rendererearlyvalue, NativeEvents$rendererearlychecked, NativeEvents$rendererearlyselectedindex, NativeEvents$functions };
//# sourceMappingURL=NativeEvents.mjs.map
