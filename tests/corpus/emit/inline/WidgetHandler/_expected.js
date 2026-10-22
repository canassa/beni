import { Inline$root, Inline$own, Inline$part, Inline$on } from "./_platform/Inline.mjs";
import { Widget$view$$html$0, Widget$view$$bind$0$0, Widget$update$$arm$0, Widget$view$$on$0 } from "./Widget.mjs";
const WidgetHandler$main = ($id$1) => {
  const $root$2 = Inline$root("root");
  const $init$3 = 0;
  let $model$4 = $init$3;
  $root$2.insertAdjacentHTML("beforeend", `<div>${Widget$view$$html$0}<button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+</button><button>+`);
  const $node$5 = $root$2.lastChild;
  Inline$own(() => {
    $node$5.remove();
  });
  const $elements$6 = $node$5.querySelectorAll("*");
  const $elements$7 = Inline$part($elements$6[0]);
  const $bind$8 = ($p$9, $p$10) => {
    Widget$view$$bind$0$0($p$9, $p$10);
  };
  {
    $bind$8($elements$7, $model$4);
  }
  const $onWidgetMsg$12 = () => {
    const $before$11 = $model$4;
    $model$4 = Widget$update$$arm$0($before$11);
    {
      $bind$8($elements$7, $model$4);
    }
  };
  const $onIncrement$14 = () => {
    const $before$13 = $model$4;
    $model$4 = $before$13 + 1;
    {
      $bind$8($elements$7, $model$4);
    }
  };
  Inline$on($elements$6[2], $onIncrement$14);
  Inline$on($elements$6[3], $onIncrement$14);
  Inline$on($elements$6[4], $onIncrement$14);
  Inline$on($elements$6[5], $onIncrement$14);
  Inline$on($elements$6[6], $onIncrement$14);
  Inline$on($elements$6[7], $onIncrement$14);
  Inline$on($elements$6[8], $onIncrement$14);
  Inline$on($elements$6[9], $onIncrement$14);
  Inline$on($elements$6[10], $onIncrement$14);
  Inline$on($elements$6[11], $onIncrement$14);
  Inline$on($elements$6[12], $onIncrement$14);
  Inline$on($elements$6[13], $onIncrement$14);
  Inline$on($elements$6[14], $onIncrement$14);
  Inline$on($elements$6[15], $onIncrement$14);
  Inline$on($elements$6[16], $onIncrement$14);
  Inline$on($elements$6[17], $onIncrement$14);
  Inline$on($elements$6[18], $onIncrement$14);
  Inline$on($elements$6[19], $onIncrement$14);
  Inline$on($elements$6[20], $onIncrement$14);
  Inline$on($elements$6[21], $onIncrement$14);
  Inline$on($elements$6[22], $onIncrement$14);
  Inline$on($elements$6[23], $onIncrement$14);
  Inline$on($elements$6[24], $onIncrement$14);
  Inline$on($elements$6[25], $onIncrement$14);
  Inline$on($elements$6[26], $onIncrement$14);
  Inline$on($elements$6[27], $onIncrement$14);
  Inline$on($elements$6[28], $onIncrement$14);
  Inline$on($elements$6[29], $onIncrement$14);
  Inline$on($elements$6[30], $onIncrement$14);
  Inline$on($elements$6[31], $onIncrement$14);
  Inline$on($elements$6[32], $onIncrement$14);
  Inline$on($elements$6[33], $onIncrement$14);
  Inline$on($elements$6[34], $onIncrement$14);
  Inline$on($elements$6[35], $onIncrement$14);
  Inline$on($elements$6[36], $onIncrement$14);
  Inline$on($elements$6[37], $onIncrement$14);
  Inline$on($elements$6[38], $onIncrement$14);
  Inline$on($elements$6[39], $onIncrement$14);
  Inline$on($elements$6[40], $onIncrement$14);
  Inline$on($elements$6[41], $onIncrement$14);
  Inline$on($elements$6[42], $onIncrement$14);
  Inline$on($elements$6[43], $onIncrement$14);
  Inline$on($elements$6[44], $onIncrement$14);
  Inline$on($elements$6[45], $onIncrement$14);
  Inline$on($elements$6[46], $onIncrement$14);
  Inline$on($elements$6[47], $onIncrement$14);
  Inline$on($elements$6[48], $onIncrement$14);
  Inline$on($elements$6[49], $onIncrement$14);
  Inline$on($elements$6[50], $onIncrement$14);
  Inline$on($elements$6[51], $onIncrement$14);
  Inline$on($elements$6[52], $onIncrement$14);
  Inline$on($elements$6[53], $onIncrement$14);
  Inline$on($elements$6[54], $onIncrement$14);
  Inline$on($elements$6[55], $onIncrement$14);
  Inline$on($elements$6[56], $onIncrement$14);
  Inline$on($elements$6[57], $onIncrement$14);
  Inline$on($elements$6[58], $onIncrement$14);
  Inline$on($elements$6[59], $onIncrement$14);
  Inline$on($elements$6[60], $onIncrement$14);
  Inline$on($elements$6[61], $onIncrement$14);
  Inline$on($elements$6[62], $onIncrement$14);
  Inline$on($elements$6[63], $onIncrement$14);
  Inline$on($elements$6[64], $onIncrement$14);
  Inline$on($elements$6[65], $onIncrement$14);
  Widget$view$$on$0($elements$7, $onWidgetMsg$12);
};
export { WidgetHandler$main };
//# sourceMappingURL=WidgetHandler.mjs.map
