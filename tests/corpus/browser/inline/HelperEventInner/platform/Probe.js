// Host-only fixture instrumentation; no beni callback is erased.
const click=(label,node)=>{const event=new globalThis.MouseEvent("click",{bubbles:true,cancelable:true});node.dispatchEvent(event);globalThis.console.log(label,event.defaultPrevented);};
export const install = () => {
 const root=globalThis.document.getElementById("root"); const insert=root.insertAdjacentHTML;
 root.insertAdjacentHTML=(position,html)=>{insert.call(root,position,html);const outside=root.querySelector("[data-role=outside] button"); const inside=root.querySelector("[data-role=inside] button");const fire=()=>{click("outside",outside);click("inside",inside);};globalThis.window.addEventListener("fire",fire);};
 return null;
};
export const start = send => {
 const bump=()=>send(1); const shown=()=>send(2); const outer=()=>send(3);
 globalThis.window.addEventListener("bump",bump);globalThis.window.addEventListener("shown",shown);globalThis.window.addEventListener("outer",outer);
 return ()=>{globalThis.window.removeEventListener("bump",bump);globalThis.window.removeEventListener("shown",shown);globalThis.window.removeEventListener("outer",outer);return null;};
};
