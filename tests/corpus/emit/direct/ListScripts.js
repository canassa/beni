import { Tea$sandbox } from "./_platform/Tea.mjs";
import { Direct$unset, Direct$insertText, Direct$row, Direct$rekey, Direct$swap, Direct$append, Direct$prepend, Direct$clear, Direct$insert, Direct$removeAt, Direct$each, Direct$positional, Direct$send, Direct$delegate, Direct$mount, Direct$wrong, Direct$same, Direct$verifyList, Direct$verify } from "./_platform/Direct.mjs";
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
  const $t$73 = ($p$72) => $p$72.id;
  const $key$74 = $t$73;
  const $L$71 = { p: $w$35, n: null, r: [], m: $make$70, o: true, k: $key$74, u: null };
  const $L$75 = { p: $w$36, n: null, r: [], m: $make$60, o: true, k: null, u: null };
  const $hEdit$82 = ($p$76, $p$77) => {
    const $k$78 = $p$76;
    $model$20 = { ...$model$20, rows: List$update($model$20.rows, $p$76, (r$25) => ({ ...r$25, label: $p$77 })) };
    {
      const $t$79 = $model$20.rows;
      const $xs$80 = $t$79;
      {
        const $r$81 = Direct$row($L$71, $xs$80, $k$78);
        if ($r$81 !== null) {
          $g$37($r$81);
        }
      }
    }
  };
  const $hSet$88 = ($p$83) => {
    const $k$84 = $p$83;
    $model$20 = { ...$model$20, rows: List$set($model$20.rows, $p$83, ListScripts$fresh($model$20, "set")), next: $model$20.next + 1 };
    {
      const $t$85 = $model$20.rows;
      const $xs$86 = $t$85;
      {
        const $r$87 = Direct$rekey($L$71, $xs$86, $k$84);
        if ($r$87 !== null) {
          $g$37($r$87);
        }
      }
    }
  };
  const $hSwap$95 = ($p$89, $p$90) => {
    const $k$91 = $p$89;
    const $k$92 = $p$90;
    $model$20 = { ...$model$20, rows: List$swap($model$20.rows, $p$89, $p$90) };
    {
      const $t$93 = $model$20.rows;
      const $xs$94 = $t$93;
      Direct$swap($L$71, $xs$94, $k$91, $k$92);
    }
  };
  const $hAppend$98 = () => {
    $model$20 = { ...$model$20, rows: List$push($model$20.rows, ListScripts$fresh($model$20, "end")), next: $model$20.next + 1 };
    {
      const $t$96 = $model$20.rows;
      const $xs$97 = $t$96;
      Direct$append($L$71, $xs$97);
    }
  };
  const $hPrepend$101 = () => {
    $model$20 = { ...$model$20, rows: List$cons(ListScripts$fresh($model$20, "front"), $model$20.rows), next: $model$20.next + 1 };
    {
      const $t$99 = $model$20.rows;
      const $xs$100 = $t$99;
      Direct$prepend($L$71, $xs$100);
    }
  };
  const $hClear$104 = () => {
    $model$20 = { ...$model$20, rows: [] };
    {
      const $t$102 = $model$20.rows;
      const $xs$103 = $t$102;
      Direct$clear($L$71);
    }
  };
  const $hInsert$109 = ($p$105) => {
    const $k$106 = $p$105;
    $model$20 = { ...$model$20, rows: List$insertAt($model$20.rows, $p$105, ListScripts$fresh($model$20, "in")), next: $model$20.next + 1 };
    {
      const $t$107 = $model$20.rows;
      const $xs$108 = $t$107;
      Direct$insert($L$71, $xs$108, $k$106);
    }
  };
  const $hRemove$52 = ($p$110) => {
    const $k$111 = $p$110;
    $model$20 = { ...$model$20, rows: List$removeAt($model$20.rows, $p$110) };
    {
      const $t$112 = $model$20.rows;
      const $xs$113 = $t$112;
      Direct$removeAt($L$71, $xs$113, $k$111);
    }
  };
  const $hMark$117 = () => {
    $model$20 = { ...$model$20, mark: `${$model$20.mark}*` };
    {
      const $t$114 = $model$20.rows;
      const $xs$115 = $t$114;
      Direct$each($L$71, $xs$115, ($r$116) => {
        $g$41($r$116);
      });
    }
  };
  const $hReverse$121 = () => {
    $model$20 = { ...$model$20, plain: List$reverse($model$20.plain) };
    {
      const $t$118 = $model$20.plain;
      const $xs$119 = $t$118;
      Direct$positional($L$75, $xs$119, ($r$120) => {
        $g$45($r$120);
      });
    }
  };
  {
    const $l$123 = ($e$122) => {
      $hEdit$82(1, "edited");
    };
    $w$25.addEventListener("click", ($e$124) => {
      Direct$send($l$123, $e$124);
    });
    const $l$126 = ($e$125) => {
      $hSet$88(0);
    };
    $w$26.addEventListener("click", ($e$127) => {
      Direct$send($l$126, $e$127);
    });
    const $l$129 = ($e$128) => {
      $hSwap$95(0, 2);
    };
    $w$27.addEventListener("click", ($e$130) => {
      Direct$send($l$129, $e$130);
    });
    const $l$132 = ($e$131) => {
      $hAppend$98();
    };
    $w$28.addEventListener("click", ($e$133) => {
      Direct$send($l$132, $e$133);
    });
    const $l$135 = ($e$134) => {
      $hPrepend$101();
    };
    $w$29.addEventListener("click", ($e$136) => {
      Direct$send($l$135, $e$136);
    });
    const $l$138 = ($e$137) => {
      $hClear$104();
    };
    $w$30.addEventListener("click", ($e$139) => {
      Direct$send($l$138, $e$139);
    });
    const $l$141 = ($e$140) => {
      $hInsert$109(1);
    };
    $w$31.addEventListener("click", ($e$142) => {
      Direct$send($l$141, $e$142);
    });
    const $l$144 = ($e$143) => {
      $hRemove$52(1);
    };
    $w$32.addEventListener("click", ($e$145) => {
      Direct$send($l$144, $e$145);
    });
    const $l$147 = ($e$146) => {
      $hMark$117();
    };
    $w$33.addEventListener("click", ($e$148) => {
      Direct$send($l$147, $e$148);
    });
    const $l$150 = ($e$149) => {
      $hReverse$121();
    };
    $w$34.addEventListener("click", ($e$151) => {
      Direct$send($l$150, $e$151);
    });
  }
  Direct$delegate($L$71, $w$35, "click", "$click");
  {
    const $t$152 = $model$20.rows;
    const $xs$153 = $t$152;
    Direct$mount($L$71, $xs$153);
  }
  {
    const $t$154 = $model$20.plain;
    const $xs$155 = $t$154;
    Direct$mount($L$75, $xs$155);
  }
  $root$1.append($r$23);
  const $check$158 = ($r$156) => {
    const $it$157 = $r$156.it;
    if (!Direct$same($it$157, $r$156.s0)) {
      Direct$wrong("the text hole at ListScripts.beni:96:61", $r$156.s0, $it$157);
    }
    if ($r$156.w1.data !== `${$it$157}`) {
      Direct$wrong("the text hole at ListScripts.beni:96:61 in the document", $r$156.w1.data, `${$it$157}`);
    }
  };
  const $check$163 = ($r$159) => {
    const $it$160 = $r$159.it;
    const $t$161 = $it$160.label;
    const $t$162 = $model$20.mark;
    if (!Direct$same($t$161, $r$159.s1)) {
      Direct$wrong("the text hole at ListScripts.beni:92:49", $r$159.s1, $t$161);
    }
    if ($r$159.x1.data !== `${$t$161}`) {
      Direct$wrong("the text hole at ListScripts.beni:92:49 in the document", $r$159.x1.data, `${$t$161}`);
    }
    if (!Direct$same($t$162, $r$159.s2)) {
      Direct$wrong("the text hole at ListScripts.beni:92:58", $r$159.s2, $t$162);
    }
    if ($r$159.x2.data !== `${$t$162}`) {
      Direct$wrong("the text hole at ListScripts.beni:92:58 in the document", $r$159.x2.data, `${$t$162}`);
    }
  };
  Direct$verify(() => {
    {
      const $t$164 = $model$20.rows;
      const $xs$165 = $t$164;
      Direct$verifyList($L$71, $xs$165, $check$163, "the `For` at ListScripts.beni:91:14", false);
    }
    {
      const $t$166 = $model$20.plain;
      const $xs$167 = $t$166;
      Direct$verifyList($L$75, $xs$167, $check$158, "the `For` at ListScripts.beni:96:14", false);
    }
  });
});
export { ListScripts$main };
//# sourceMappingURL=ListScripts.mjs.map
