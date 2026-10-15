import { Browser$Events$onKeyDown } from "./_platform/_browser/Browser/Events.mjs";
import { Html$key } from "./_platform/_html/Html.mjs";
import { List$base, List$offset } from "./_core/List.mjs";
const Keyboard$Enter = { $: "Enter", a: null };
const Keyboard$Maybe$Nothing = { $: "Nothing", a: null };
const Keyboard$Spacebar = { $: "Spacebar", a: null };
const Keyboard$Tab = { $: "Tab", a: null };
const Keyboard$Key$$eq = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Character":
      return $x.a === $y.a;
    case "Alt":
      return true;
    case "AltGraph":
      return true;
    case "CapsLock":
      return true;
    case "Control":
      return true;
    case "Fn":
      return true;
    case "FnLock":
      return true;
    case "Hyper":
      return true;
    case "Meta":
      return true;
    case "NumLock":
      return true;
    case "ScrollLock":
      return true;
    case "Shift":
      return true;
    case "Super":
      return true;
    case "Symbol":
      return true;
    case "SymbolLock":
      return true;
    case "Enter":
      return true;
    case "Tab":
      return true;
    case "Spacebar":
      return true;
    case "ArrowDown":
      return true;
    case "ArrowLeft":
      return true;
    case "ArrowRight":
      return true;
    case "ArrowUp":
      return true;
    case "End":
      return true;
    case "Home":
      return true;
    case "PageDown":
      return true;
    case "PageUp":
      return true;
    case "Backspace":
      return true;
    case "Clear":
      return true;
    case "Copy":
      return true;
    case "CrSel":
      return true;
    case "Cut":
      return true;
    case "Delete":
      return true;
    case "EraseEof":
      return true;
    case "ExSel":
      return true;
    case "Insert":
      return true;
    case "Paste":
      return true;
    case "Redo":
      return true;
    case "Undo":
      return true;
    case "F1":
      return true;
    case "F2":
      return true;
    case "F3":
      return true;
    case "F4":
      return true;
    case "F5":
      return true;
    case "F6":
      return true;
    case "F7":
      return true;
    case "F8":
      return true;
    case "F9":
      return true;
    case "F10":
      return true;
    case "F11":
      return true;
    case "F12":
      return true;
    case "F13":
      return true;
    case "F14":
      return true;
    case "F15":
      return true;
    case "F16":
      return true;
    case "F17":
      return true;
    case "F18":
      return true;
    case "F19":
      return true;
    case "F20":
      return true;
    case "Again":
      return true;
    case "Attn":
      return true;
    case "Cancel":
      return true;
    case "ContextMenu":
      return true;
    case "Escape":
      return true;
    case "Execute":
      return true;
    case "Find":
      return true;
    case "Finish":
      return true;
    case "Help":
      return true;
    case "Pause":
      return true;
    case "Play":
      return true;
    case "Props":
      return true;
    case "Select":
      return true;
    case "ZoomIn":
      return true;
    case "ZoomOut":
      return true;
    case "AppSwitch":
      return true;
    case "Call":
      return true;
    case "Camera":
      return true;
    case "CameraFocus":
      return true;
    case "EndCall":
      return true;
    case "GoBack":
      return true;
    case "GoHome":
      return true;
    case "HeadsetHook":
      return true;
    case "LastNumberRedial":
      return true;
    case "Notification":
      return true;
    case "MannerMode":
      return true;
    case "VoiceDial":
      return true;
    case "ChannelDown":
      return true;
    case "ChannelUp":
      return true;
    case "MediaFastForward":
      return true;
    case "MediaPause":
      return true;
    case "MediaPlay":
      return true;
    case "MediaPlayPause":
      return true;
    case "MediaRecord":
      return true;
    case "MediaRewind":
      return true;
    case "MediaStop":
      return true;
    case "MediaTrackNext":
      return true;
    default:
      return true;
  }
};
const Keyboard$rawValue = ($p$1) => {
  const key$1 = $p$1.a;
  return key$1;
};
const Keyboard$downs = (toMsg$1) => Browser$Events$onKeyDown((event$2) => toMsg$1({ $: "RawKey", a: Html$key(event$2) }));
const Keyboard$oneOf = (fns$1, key$2) => {
  const $t$2 = List$base(fns$1);
  fns$1 = List$offset(fns$1);
  while ($t$2.length !== fns$1) {
    const fn$3 = $t$2[fns$1];
    const rest$4 = fns$1 + 1;
    const $t$4 = fn$3(key$2);
    if ($t$4.$ === "Just") {
      const a$5 = $t$4.a;
      return { $: "Just", a: a$5 };
    } else {
      fns$1 = rest$4;
    }
  }
  return Keyboard$Maybe$Nothing;
};
const Keyboard$whitespaceKey = ($p$5) => {
  const value$1 = $p$5.a;
  switch (value$1) {
    case "Enter":
      {
        return { $: "Just", a: Keyboard$Enter };
      }
    case "Tab":
      {
        return { $: "Just", a: Keyboard$Tab };
      }
    case "Spacebar":
      {
        return { $: "Just", a: Keyboard$Spacebar };
      }
    case " ":
      {
        return { $: "Just", a: Keyboard$Spacebar };
      }
    default:
      {
        return Keyboard$Maybe$Nothing;
      }
  }
};
export { Keyboard$Key$$eq, Keyboard$rawValue, Keyboard$downs, Keyboard$oneOf, Keyboard$whitespaceKey };
//# sourceMappingURL=Keyboard.mjs.map
