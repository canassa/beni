// Host-only fixture instrumentation; no beni callback is erased.
export const start = _send => {
 const node=globalThis.document.querySelector("[data-role=retained]"); const parent=node.parentNode;
 const bubbled=()=>globalThis.console.log("host-bubbled");
 parent.addEventListener("click",bubbled);
 const fire=()=>{const event=new globalThis.MouseEvent("click",{bubbles:true,cancelable:true});node.dispatchEvent(event);globalThis.console.log("host-defaultPrevented",event.defaultPrevented);};
 globalThis.window.addEventListener("probehidden",fire);
 return ()=>{globalThis.window.removeEventListener("probehidden",fire);parent.removeEventListener("click",bubbled);return null;};
};
