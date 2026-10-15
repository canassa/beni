const Dict$Leaf = { $: "Leaf", a: null, b: null, c: null, d: null, e: null };
const Dict$Maybe$Nothing = { $: "Nothing", a: null };
const Dict$empty = { $: "Dict", a: Dict$Leaf };
const Dict$getHelp = ($m$0, tree$1, targetKey$2) => {
  while (tree$1.$ === "Node") {
    const key$3 = tree$1.b;
    const value$4 = tree$1.c;
    const left$5 = tree$1.d;
    const right$6 = tree$1.e;
    switch ($m$0(targetKey$2, key$3)) {
      case "LT":
        {
          tree$1 = left$5;
          continue;
        }
      case "EQ":
        {
          return { $: "Just", a: value$4 };
        }
      default:
        {
          tree$1 = right$6;
          continue;
        }
    }
  }
  return Dict$Maybe$Nothing;
};
const Dict$get = ($m$0, $p$1, targetKey$2) => {
  const tree$1 = $p$1.a;
  return Dict$getHelp($m$0, tree$1, targetKey$2);
};
const Dict$member = ($m$0, dict$1, key$2) => Dict$get($m$0, dict$1, key$2).$ === "Just" ? true : false;
const Dict$blacken = (tree$1) => {
  $j$0$1: {
    if (tree$1.$ === "Node") {
      if (tree$1.a === "Red") {
        const key$2 = tree$1.b;
        const value$3 = tree$1.c;
        const left$4 = tree$1.d;
        const right$5 = tree$1.e;
        return { $: "Node", a: "Black", b: key$2, c: value$3, d: left$4, e: right$5 };
      } else {
        break $j$0$1;
      }
    } else {
      break $j$0$1;
    }
  }
  return tree$1;
};
const Dict$balance = (color$1, key$2, value$3, left$4, right$5) => {
  $j$0$1: {
    if (right$5.$ === "Node") {
      if (right$5.a === "Red") {
        const rK$6 = right$5.b;
        const rV$7 = right$5.c;
        const rLeft$8 = right$5.d;
        const rRight$9 = right$5.e;
        $j$1$1: {
          if (left$4.$ === "Node") {
            if (left$4.a === "Red") {
              const lK$10 = left$4.b;
              const lV$11 = left$4.c;
              const lLeft$12 = left$4.d;
              const lRight$13 = left$4.e;
              return { $: "Node", a: "Red", b: key$2, c: value$3, d: { $: "Node", a: "Black", b: lK$10, c: lV$11, d: lLeft$12, e: lRight$13 }, e: { $: "Node", a: "Black", b: rK$6, c: rV$7, d: rLeft$8, e: rRight$9 } };
            } else {
              break $j$1$1;
            }
          } else {
            break $j$1$1;
          }
        }
        return { $: "Node", a: color$1, b: rK$6, c: rV$7, d: { $: "Node", a: "Red", b: key$2, c: value$3, d: left$4, e: rLeft$8 }, e: rRight$9 };
      } else {
        break $j$0$1;
      }
    } else {
      break $j$0$1;
    }
  }
  $j$1$1: {
    if (left$4.$ === "Node") {
      if (left$4.a === "Red") {
        if (left$4.d.$ === "Node") {
          if (left$4.d.a === "Red") {
            const lK$14 = left$4.b;
            const lV$15 = left$4.c;
            const llK$16 = left$4.d.b;
            const llV$17 = left$4.d.c;
            const llLeft$18 = left$4.d.d;
            const llRight$19 = left$4.d.e;
            const lRight$20 = left$4.e;
            return { $: "Node", a: "Red", b: lK$14, c: lV$15, d: { $: "Node", a: "Black", b: llK$16, c: llV$17, d: llLeft$18, e: llRight$19 }, e: { $: "Node", a: "Black", b: key$2, c: value$3, d: lRight$20, e: right$5 } };
          } else {
            break $j$1$1;
          }
        } else {
          break $j$1$1;
        }
      } else {
        break $j$1$1;
      }
    } else {
      break $j$1$1;
    }
  }
  return { $: "Node", a: color$1, b: key$2, c: value$3, d: left$4, e: right$5 };
};
const Dict$insertHelp = ($m$0, tree$1, key$2, value$3) => {
  if (tree$1.$ === "Node") {
    const nColor$4 = tree$1.a;
    const nKey$5 = tree$1.b;
    const nValue$6 = tree$1.c;
    const nLeft$7 = tree$1.d;
    const nRight$8 = tree$1.e;
    switch ($m$0(key$2, nKey$5)) {
      case "LT":
        {
          return Dict$balance(nColor$4, nKey$5, nValue$6, Dict$insertHelp($m$0, nLeft$7, key$2, value$3), nRight$8);
        }
      case "EQ":
        {
          return { $: "Node", a: nColor$4, b: nKey$5, c: value$3, d: nLeft$7, e: nRight$8 };
        }
      default:
        {
          return Dict$balance(nColor$4, nKey$5, nValue$6, nLeft$7, Dict$insertHelp($m$0, nRight$8, key$2, value$3));
        }
    }
  } else {
    return { $: "Node", a: "Red", b: key$2, c: value$3, d: Dict$Leaf, e: Dict$Leaf };
  }
};
const Dict$insert = ($m$0, $p$2, key$2, value$3) => {
  const tree$1 = $p$2.a;
  return { $: "Dict", a: Dict$blacken(Dict$insertHelp($m$0, tree$1, key$2, value$3)) };
};
const Dict$moveRedLeft = (tree$1) => {
  $j$0$1: {
    if (tree$1.$ === "Node") {
      if (tree$1.d.$ === "Node") {
        if (tree$1.e.$ === "Node") {
          const k$2 = tree$1.b;
          const v$3 = tree$1.c;
          const lK$4 = tree$1.d.b;
          const lV$5 = tree$1.d.c;
          const lLeft$6 = tree$1.d.d;
          const lRight$7 = tree$1.d.e;
          const rK$8 = tree$1.e.b;
          const rV$9 = tree$1.e.c;
          const rLeft$10 = tree$1.e.d;
          const rRight$11 = tree$1.e.e;
          $j$1$1: {
            if (rLeft$10.$ === "Node") {
              if (rLeft$10.a === "Red") {
                const rlK$12 = rLeft$10.b;
                const rlV$13 = rLeft$10.c;
                const rlL$14 = rLeft$10.d;
                const rlR$15 = rLeft$10.e;
                return { $: "Node", a: "Red", b: rlK$12, c: rlV$13, d: { $: "Node", a: "Black", b: k$2, c: v$3, d: { $: "Node", a: "Red", b: lK$4, c: lV$5, d: lLeft$6, e: lRight$7 }, e: rlL$14 }, e: { $: "Node", a: "Black", b: rK$8, c: rV$9, d: rlR$15, e: rRight$11 } };
              } else {
                break $j$1$1;
              }
            } else {
              break $j$1$1;
            }
          }
          return { $: "Node", a: "Black", b: k$2, c: v$3, d: { $: "Node", a: "Red", b: lK$4, c: lV$5, d: lLeft$6, e: lRight$7 }, e: { $: "Node", a: "Red", b: rK$8, c: rV$9, d: rLeft$10, e: rRight$11 } };
        } else {
          break $j$0$1;
        }
      } else {
        break $j$0$1;
      }
    } else {
      break $j$0$1;
    }
  }
  return tree$1;
};
const Dict$getMin = (tree$1) => {
  for (;;) {
    $j$0$1: {
      if (tree$1.$ === "Node") {
        if (tree$1.d.$ === "Node") {
          const left$2 = tree$1.d;
          tree$1 = left$2;
          continue;
        } else {
          break $j$0$1;
        }
      } else {
        break $j$0$1;
      }
    }
    return tree$1;
  }
};
const Dict$removeMin = (tree$1) => {
  $j$0$1: {
    if (tree$1.$ === "Node") {
      if (tree$1.d.$ === "Node") {
        const color$2 = tree$1.a;
        const key$3 = tree$1.b;
        const value$4 = tree$1.c;
        const lColor$5 = tree$1.d.a;
        const lLeft$6 = tree$1.d.d;
        const left$7 = tree$1.d;
        const right$8 = tree$1.e;
        if (lColor$5 === "Black") {
          $j$2$1: {
            if (lLeft$6.$ === "Node") {
              if (lLeft$6.a === "Red") {
                return { $: "Node", a: color$2, b: key$3, c: value$4, d: Dict$removeMin(left$7), e: right$8 };
              } else {
                break $j$2$1;
              }
            } else {
              break $j$2$1;
            }
          }
          const $t$3 = Dict$moveRedLeft(tree$1);
          if ($t$3.$ === "Node") {
            const nColor$9 = $t$3.a;
            const nKey$10 = $t$3.b;
            const nValue$11 = $t$3.c;
            const nLeft$12 = $t$3.d;
            const nRight$13 = $t$3.e;
            return Dict$balance(nColor$9, nKey$10, nValue$11, Dict$removeMin(nLeft$12), nRight$13);
          } else {
            return Dict$Leaf;
          }
        } else {
          return { $: "Node", a: color$2, b: key$3, c: value$4, d: Dict$removeMin(left$7), e: right$8 };
        }
      } else {
        break $j$0$1;
      }
    } else {
      break $j$0$1;
    }
  }
  return Dict$Leaf;
};
const Dict$removeHelpEQGT = ($m$0, tree$1, targetKey$2) => {
  if (tree$1.$ === "Node") {
    const color$3 = tree$1.a;
    const key$4 = tree$1.b;
    const value$5 = tree$1.c;
    const left$6 = tree$1.d;
    const right$7 = tree$1.e;
    if ($m$0(targetKey$2, key$4) === "EQ") {
      const $t$4 = Dict$getMin(right$7);
      if ($t$4.$ === "Node") {
        const minKey$8 = $t$4.b;
        const minValue$9 = $t$4.c;
        return Dict$balance(color$3, minKey$8, minValue$9, left$6, Dict$removeMin(right$7));
      } else {
        return Dict$Leaf;
      }
    } else {
      return Dict$balance(color$3, key$4, value$5, left$6, Dict$removeHelp($m$0, right$7, targetKey$2));
    }
  } else {
    return Dict$Leaf;
  }
};
const Dict$moveRedRight = (tree$1) => {
  $j$0$1: {
    if (tree$1.$ === "Node") {
      if (tree$1.d.$ === "Node") {
        if (tree$1.e.$ === "Node") {
          const k$2 = tree$1.b;
          const v$3 = tree$1.c;
          const lK$4 = tree$1.d.b;
          const lV$5 = tree$1.d.c;
          const lLeft$6 = tree$1.d.d;
          const lRight$7 = tree$1.d.e;
          const rK$8 = tree$1.e.b;
          const rV$9 = tree$1.e.c;
          const rLeft$10 = tree$1.e.d;
          const rRight$11 = tree$1.e.e;
          $j$1$1: {
            if (lLeft$6.$ === "Node") {
              if (lLeft$6.a === "Red") {
                const llK$12 = lLeft$6.b;
                const llV$13 = lLeft$6.c;
                const llLeft$14 = lLeft$6.d;
                const llRight$15 = lLeft$6.e;
                return { $: "Node", a: "Red", b: lK$4, c: lV$5, d: { $: "Node", a: "Black", b: llK$12, c: llV$13, d: llLeft$14, e: llRight$15 }, e: { $: "Node", a: "Black", b: k$2, c: v$3, d: lRight$7, e: { $: "Node", a: "Red", b: rK$8, c: rV$9, d: rLeft$10, e: rRight$11 } } };
              } else {
                break $j$1$1;
              }
            } else {
              break $j$1$1;
            }
          }
          return { $: "Node", a: "Black", b: k$2, c: v$3, d: { $: "Node", a: "Red", b: lK$4, c: lV$5, d: lLeft$6, e: lRight$7 }, e: { $: "Node", a: "Red", b: rK$8, c: rV$9, d: rLeft$10, e: rRight$11 } };
        } else {
          break $j$0$1;
        }
      } else {
        break $j$0$1;
      }
    } else {
      break $j$0$1;
    }
  }
  return tree$1;
};
const Dict$removeHelpPrepEQGT = (tree$1, color$2, key$3, value$4, left$5, right$6) => {
  $j$0$1: {
    if (left$5.$ === "Node") {
      if (left$5.a === "Red") {
        const lK$7 = left$5.b;
        const lV$8 = left$5.c;
        const lLeft$9 = left$5.d;
        const lRight$10 = left$5.e;
        return { $: "Node", a: color$2, b: lK$7, c: lV$8, d: lLeft$9, e: { $: "Node", a: "Red", b: key$3, c: value$4, d: lRight$10, e: right$6 } };
      } else {
        break $j$0$1;
      }
    } else {
      break $j$0$1;
    }
  }
  $j$1$2: {
    if (right$6.$ === "Node") {
      if (right$6.a === "Black") {
        if (right$6.d.$ === "Node") {
          if (right$6.d.a === "Black") {
            return Dict$moveRedRight(tree$1);
          } else {
            break $j$1$2;
          }
        } else {
          return Dict$moveRedRight(tree$1);
        }
      } else {
        break $j$1$2;
      }
    } else {
      break $j$1$2;
    }
  }
  return tree$1;
};
const Dict$removeHelp = ($m$0, tree$1, targetKey$2) => {
  if (tree$1.$ === "Node") {
    const color$3 = tree$1.a;
    const key$4 = tree$1.b;
    const value$5 = tree$1.c;
    const left$6 = tree$1.d;
    const right$7 = tree$1.e;
    if ($m$0(targetKey$2, key$4) === "LT") {
      $j$2$1: {
        if (left$6.$ === "Node") {
          if (left$6.a === "Black") {
            const lLeft$8 = left$6.d;
            $j$3$1: {
              if (lLeft$8.$ === "Node") {
                if (lLeft$8.a === "Red") {
                  return { $: "Node", a: color$3, b: key$4, c: value$5, d: Dict$removeHelp($m$0, left$6, targetKey$2), e: right$7 };
                } else {
                  break $j$3$1;
                }
              } else {
                break $j$3$1;
              }
            }
            const $t$5 = Dict$moveRedLeft(tree$1);
            if ($t$5.$ === "Node") {
              const nColor$9 = $t$5.a;
              const nKey$10 = $t$5.b;
              const nValue$11 = $t$5.c;
              const nLeft$12 = $t$5.d;
              const nRight$13 = $t$5.e;
              return Dict$balance(nColor$9, nKey$10, nValue$11, Dict$removeHelp($m$0, nLeft$12, targetKey$2), nRight$13);
            } else {
              return Dict$Leaf;
            }
          } else {
            break $j$2$1;
          }
        } else {
          break $j$2$1;
        }
      }
      return { $: "Node", a: color$3, b: key$4, c: value$5, d: Dict$removeHelp($m$0, left$6, targetKey$2), e: right$7 };
    } else {
      return Dict$removeHelpEQGT($m$0, Dict$removeHelpPrepEQGT(tree$1, color$3, key$4, value$5, left$6, right$7), targetKey$2);
    }
  } else {
    return Dict$Leaf;
  }
};
const Dict$remove = ($m$0, $p$6, key$2) => {
  const tree$1 = $p$6.a;
  return { $: "Dict", a: Dict$blacken(Dict$removeHelp($m$0, tree$1, key$2)) };
};
const Dict$focus = ($m$0, dict$1, targetKey$2, alter$3) => {
  const $t$7 = alter$3(Dict$get($m$0, dict$1, targetKey$2));
  if ($t$7.$ === "Just") {
    const value$4 = $t$7.a;
    return Dict$insert($m$0, dict$1, targetKey$2, value$4);
  } else {
    return Dict$remove($m$0, dict$1, targetKey$2);
  }
};
const Dict$update = ($m$0, dict$1, targetKey$2, alter$3) => Dict$focus($m$0, dict$1, targetKey$2, alter$3);
const Dict$foldlTree = (tree$1, acc$2, func$3) => {
  while (tree$1.$ === "Node") {
    const key$4 = tree$1.b;
    const value$5 = tree$1.c;
    const left$6 = tree$1.d;
    const right$7 = tree$1.e;
    tree$1 = right$7;
    acc$2 = func$3(key$4, value$5, Dict$foldlTree(left$6, acc$2, func$3));
  }
  return acc$2;
};
const Dict$foldl = ($p$8, acc$2, func$3) => {
  const tree$1 = $p$8.a;
  return Dict$foldlTree(tree$1, acc$2, func$3);
};
export { Dict$empty, Dict$get, Dict$member, Dict$insert, Dict$remove, Dict$update, Dict$foldl };
//# sourceMappingURL=Dict.mjs.map
