import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$unset, Direct$insertText, Direct$keyMap, Direct$row, Direct$rekey, Direct$swap, Direct$append, Direct$prepend, Direct$clear, Direct$insert, Direct$removeAt, Direct$each, Direct$positional, Direct$send, Direct$delegate, Direct$mount, Direct$wrong, Direct$same, Direct$verifyList, Direct$verify } from "./_platform/Direct.mjs";
import { List$update, List$set, List$swap, List$push, List$cons, List$insertAt, List$removeAt, List$reverse } from "./_core/List.mjs";
const ListScripts$fresh = (model$1, label$2) => ({ id: model$1.next, label: label$2 });
const ListScripts$main = Tea$sandbox(($root$1, $t$2) => {
  const $t$17 = [];
  const $t$18 = ["a", "b"];
  const init$19 = { mark: "", next: 0, plain: $t$18, rows: $t$17 };
  let $model$20 = init$19;
  $t$2.innerHTML = "<li><!><!>";
  const $T$21 = $t$2.content.firstChild;
  $t$2.innerHTML = "<li> ";
  const $T$22 = $t$2.content.firstChild;
  $t$2.innerHTML = "<main><button>edit</button><button>set</button><button>swap</button><button>append</button><button>prepend</button><button>clear</button><button>insert</button><button>remove</button><button>mark</button><button>reverse</button><ul></ul><ol>";
  const $r$23 = $t$2.content;
  const $w$24 = $r$23.firstChild;
  const $w$25 = $w$24.firstChild;
  const $w$26 = $w$25.nextSibling;
  const $w$27 = $w$26.nextSibling;
  const $w$28 = $w$27.nextSibling;
  const $w$29 = $w$28.nextSibling;
  const $w$30 = $w$29.nextSibling;
  const $w$31 = $w$30.nextSibling;
  const $w$32 = $w$31.nextSibling;
  const $w$33 = $w$32.nextSibling;
  const $w$34 = $w$33.nextSibling;
  const $w$35 = $w$34.nextSibling;
  const $w$36 = $w$35.nextSibling;
  const $g$37 = ($r$38) => {
    const $it$39 = $r$38.it;
    const $t$40 = $it$39.label;
    if ($t$40 !== $r$38.s1) {
      $r$38.x1.data = $t$40;
      $r$38.s1 = $t$40;
    }
  };
  const $g$41 = ($r$42) => {
    const $it$43 = $r$42.it;
    const $t$44 = $model$20.mark;
    if ($t$44 !== $r$42.s2) {
      $r$42.x2.data = $t$44;
      $r$42.s2 = $t$44;
    }
  };
  const $g$45 = ($r$46) => {
    const $it$47 = $r$46.it;
    if ($it$47 !== $r$46.s0) {
      $r$46.w1.data = $it$47;
      $r$46.s0 = $it$47;
    }
  };
  const $l$53 = ($e$48, $r$49) => {
    const $it$50 = $r$49.it;
    const $t$51 = $it$50.id;
    $hRemove$52($t$51);
  };
  const $make$60 = ($it$54, $L$55, $j$56) => {
    const $e$57 = $T$22.cloneNode(true);
    const $w$58 = $e$57.firstChild;
    const $r$59 = { e: $e$57, it: $it$54, w1: $w$58, s0: Direct$unset };
    $e$57.$v = $L$55;
    $g$45($r$59);
    return $r$59;
  };
  const $make$70 = ($it$61, $L$62, $j$63) => {
    const $e$64 = $T$21.cloneNode(true);
    const $w$65 = $e$64.firstChild;
    const $w$66 = $w$65.nextSibling;
    const $x$67 = Direct$insertText($e$64, $w$65, "");
    const $x$68 = Direct$insertText($e$64, $w$66, "");
    const $r$69 = { e: $e$64, it: $it$61, l: $L$62, x1: $x$67, x2: $x$68, s1: Direct$unset, s2: Direct$unset };
    $e$64.$r = $r$69;
    $e$64.$v = $L$62;
    $e$64.$click = $l$53;
    $g$37($r$69);
    $g$41($r$69);
    return $r$69;
  };
  const $W$72 = ($r$73) => {
    $g$37($r$73);
    $g$41($r$73);
  };
  const $W$71 = ($r$74) => {
    $g$45($r$74);
  };
  const $t$77 = ($p$76) => $p$76.id;
  const $key$78 = $t$77;
  const $L$75 = { p: $w$35, n: null, r: [], m: $make$70, o: true, k: $key$78, u: null, w: $W$72, x: Direct$keyMap(), d: 0, z: Direct$unset, i: false };
  const $L$79 = { p: $w$36, n: null, r: [], m: $make$60, o: true, k: null, u: null, w: $W$71, x: null, d: null, z: Direct$unset, i: false };
  const $hEdit$86 = ($p$80, $p$81) => {
    const $k$82 = $p$80;
    $model$20 = { ...$model$20, rows: List$update($model$20.rows, $p$80, (r$25) => ({ ...r$25, label: $p$81 })) };
    {
      const $t$83 = $model$20.rows;
      const $xs$84 = $t$83;
      {
        const $r$85 = Direct$row($L$75, $xs$84, $k$82);
        if ($r$85 !== null) {
          $g$37($r$85);
        }
      }
    }
  };
  const $hSet$92 = ($p$87) => {
    const $k$88 = $p$87;
    $model$20 = { ...$model$20, rows: List$set($model$20.rows, $p$87, ListScripts$fresh($model$20, "set")), next: $model$20.next + 1 };
    {
      const $t$89 = $model$20.rows;
      const $xs$90 = $t$89;
      {
        const $r$91 = Direct$rekey($L$75, $xs$90, $k$88);
        if ($r$91 !== null) {
          $g$37($r$91);
        }
      }
    }
  };
  const $hSwap$99 = ($p$93, $p$94) => {
    const $k$95 = $p$93;
    const $k$96 = $p$94;
    $model$20 = { ...$model$20, rows: List$swap($model$20.rows, $p$93, $p$94) };
    {
      const $t$97 = $model$20.rows;
      const $xs$98 = $t$97;
      Direct$swap($L$75, $xs$98, $k$95, $k$96);
    }
  };
  const $hAppend$102 = () => {
    $model$20 = { ...$model$20, rows: List$push($model$20.rows, ListScripts$fresh($model$20, "end")), next: $model$20.next + 1 };
    {
      const $t$100 = $model$20.rows;
      const $xs$101 = $t$100;
      Direct$append($L$75, $xs$101);
    }
  };
  const $hPrepend$105 = () => {
    $model$20 = { ...$model$20, rows: List$cons(ListScripts$fresh($model$20, "front"), $model$20.rows), next: $model$20.next + 1 };
    {
      const $t$103 = $model$20.rows;
      const $xs$104 = $t$103;
      Direct$prepend($L$75, $xs$104);
    }
  };
  const $hClear$108 = () => {
    $model$20 = { ...$model$20, rows: [] };
    {
      const $t$106 = $model$20.rows;
      const $xs$107 = $t$106;
      Direct$clear($L$75);
    }
  };
  const $hInsert$113 = ($p$109) => {
    const $k$110 = $p$109;
    $model$20 = { ...$model$20, rows: List$insertAt($model$20.rows, $p$109, ListScripts$fresh($model$20, "in")), next: $model$20.next + 1 };
    {
      const $t$111 = $model$20.rows;
      const $xs$112 = $t$111;
      Direct$insert($L$75, $xs$112, $k$110);
    }
  };
  const $hRemove$52 = ($p$114) => {
    const $k$115 = $p$114;
    $model$20 = { ...$model$20, rows: List$removeAt($model$20.rows, $p$114) };
    {
      const $t$116 = $model$20.rows;
      const $xs$117 = $t$116;
      Direct$removeAt($L$75, $xs$117, $k$115);
    }
  };
  const $hMark$121 = () => {
    $model$20 = { ...$model$20, mark: `${$model$20.mark}*` };
    {
      const $t$118 = $model$20.rows;
      const $xs$119 = $t$118;
      Direct$each($L$75, $xs$119, ($r$120) => {
        $g$41($r$120);
      });
    }
  };
  const $hReverse$124 = () => {
    $model$20 = { ...$model$20, plain: List$reverse($model$20.plain) };
    {
      const $t$122 = $model$20.plain;
      const $xs$123 = $t$122;
      Direct$positional($L$79, $xs$123, $W$71);
    }
  };
  {
    const $l$126 = ($e$125) => {
      $hEdit$86(1, "edited");
    };
    $w$25.addEventListener("click", ($e$127) => {
      Direct$send($l$126, $e$127);
    });
    const $l$129 = ($e$128) => {
      $hSet$92(0);
    };
    $w$26.addEventListener("click", ($e$130) => {
      Direct$send($l$129, $e$130);
    });
    const $l$132 = ($e$131) => {
      $hSwap$99(0, 2);
    };
    $w$27.addEventListener("click", ($e$133) => {
      Direct$send($l$132, $e$133);
    });
    const $l$135 = ($e$134) => {
      $hAppend$102();
    };
    $w$28.addEventListener("click", ($e$136) => {
      Direct$send($l$135, $e$136);
    });
    const $l$138 = ($e$137) => {
      $hPrepend$105();
    };
    $w$29.addEventListener("click", ($e$139) => {
      Direct$send($l$138, $e$139);
    });
    const $l$141 = ($e$140) => {
      $hClear$108();
    };
    $w$30.addEventListener("click", ($e$142) => {
      Direct$send($l$141, $e$142);
    });
    const $l$144 = ($e$143) => {
      $hInsert$113(1);
    };
    $w$31.addEventListener("click", ($e$145) => {
      Direct$send($l$144, $e$145);
    });
    const $l$147 = ($e$146) => {
      $hRemove$52(1);
    };
    $w$32.addEventListener("click", ($e$148) => {
      Direct$send($l$147, $e$148);
    });
    const $l$150 = ($e$149) => {
      $hMark$121();
    };
    $w$33.addEventListener("click", ($e$151) => {
      Direct$send($l$150, $e$151);
    });
    const $l$153 = ($e$152) => {
      $hReverse$124();
    };
    $w$34.addEventListener("click", ($e$154) => {
      Direct$send($l$153, $e$154);
    });
  }
  Direct$delegate($L$75, $w$35, "click", "$click");
  {
    const $t$155 = $model$20.rows;
    const $xs$156 = $t$155;
    Direct$mount($L$75, $xs$156);
  }
  {
    const $t$157 = $model$20.plain;
    const $xs$158 = $t$157;
    Direct$mount($L$79, $xs$158);
  }
  $root$1.append($r$23);
  const $check$161 = ($r$159) => {
    const $it$160 = $r$159.it;
    if (!Direct$same($it$160, $r$159.s0)) {
      Direct$wrong("the text hole at ListScripts.beni:96:61", $r$159.s0, $it$160);
    }
    if ($r$159.w1.data !== `${$it$160}`) {
      Direct$wrong("the text hole at ListScripts.beni:96:61 in the document", $r$159.w1.data, `${$it$160}`);
    }
  };
  const $check$166 = ($r$162) => {
    const $it$163 = $r$162.it;
    const $t$164 = $it$163.label;
    const $t$165 = $model$20.mark;
    if (!Direct$same($t$164, $r$162.s1)) {
      Direct$wrong("the text hole at ListScripts.beni:92:49", $r$162.s1, $t$164);
    }
    if ($r$162.x1.data !== `${$t$164}`) {
      Direct$wrong("the text hole at ListScripts.beni:92:49 in the document", $r$162.x1.data, `${$t$164}`);
    }
    if (!Direct$same($t$165, $r$162.s2)) {
      Direct$wrong("the text hole at ListScripts.beni:92:58", $r$162.s2, $t$165);
    }
    if ($r$162.x2.data !== `${$t$165}`) {
      Direct$wrong("the text hole at ListScripts.beni:92:58 in the document", $r$162.x2.data, `${$t$165}`);
    }
  };
  Direct$verify(() => {
    {
      const $t$167 = $model$20.rows;
      const $xs$168 = $t$167;
      Direct$verifyList($L$75, $xs$168, $check$166, "the `For` at ListScripts.beni:91:14", false);
    }
    {
      const $t$169 = $model$20.plain;
      const $xs$170 = $t$169;
      Direct$verifyList($L$79, $xs$170, $check$161, "the `For` at ListScripts.beni:96:14", false);
    }
  });
});
export { ListScripts$main };
//# sourceMappingURL=ListScripts.mjs.map
