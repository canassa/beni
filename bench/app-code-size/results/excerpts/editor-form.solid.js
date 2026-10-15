// en: 790 B raw
let en = ge('<div class="editor-page"><div class="container page"><div class="row"><div class="col-md-10 offset-md-1 col-xs-12"><form><fieldset><fieldset class="form-group"><input type="text" class="form-control form-control-lg" placeholder="Article Title"></fieldset><fieldset class="form-group"><input type="text" class="form-control" placeholder="What\'s this article about?"></fieldset><fieldset class="form-group"><textarea class="form-control" rows="8" placeholder="Write your article (in markdown)"></textarea></fieldset><fieldset class="form-group"><input type="text" class="form-control" placeholder="Enter tags"><div class="tag-list"></div></fieldset><button class="btn btn-lg pull-xs-right btn-primary" type="button">Publish Article</button></fieldset></form></div></div></div></div>');
// tn: 82 B raw
let tn = ge('<span class="tag-default tag-pill"><i class="ion-close-round"></i></span>');
// nn: 1823 B raw
let nn = Object.freeze({
  __proto__: null,
  default: ({slug: e}) => {
    const [t, {createArticle: n, updateArticle: r}] = ze(), [o, i] = Le({
      tagInput: "",
      tagList: []
    }), l = e => t => i(e, t.target.value), s = () => {
      o.tagInput && i(e => {
        e.tagList.push(e.tagInput.trim()), e.tagInput = "";
      });
    }, a = e => {
      !o.inProgress && i("tagList", t => t.filter(t => t !== e));
    }, c = e => {
      switch (e.keyCode) {
       case 13:
       case 9:
       case 188:
        9 !== e.keyCode && e.preventDefault(), s();
      }
    }, u = t => {
      t.preventDefault(), i({
        inProgress: !0
      });
      const {inProgress: l, tagsInput: s, ...a} = o;
      (e ? r : n)(a).then(e => location.hash = `/article/${e.slug}`).catch(e => i({
        errors: e
      })).finally(() => i({
        inProgress: !1
      }));
    };
    return w(() => {
      let n;
      e && (n = t.articles[e]) && i(n);
    }), (() => {
      const e = en.cloneNode(!0), t = e.firstChild.firstChild.firstChild, n = t.firstChild, r = n.firstChild.firstChild, i = r.firstChild, d = r.nextSibling, f = d.firstChild, g = d.nextSibling, v = g.firstChild, h = g.nextSibling, p = h.firstChild, m = p.nextSibling, b = h.nextSibling;
      return me(t, Z(Ot, {
        get errors() {
          return o.errors;
        }
      }), n), pe(i, "change", l("title")), pe(f, "change", l("description")), pe(v, "change", l("body")), 
      p.$$keyup = c, p.addEventListener("blur", s), pe(p, "change", l("tagInput")), me(m, Z(ie, {
        get each() {
          return o.tagList;
        },
        children: e => (() => {
          const t = tn.cloneNode(!0), n = t.firstChild;
          return n.$$click = a, n.$$clickData = e, me(t, e, null), t;
        })()
      })), b.$$click = u, $(e => {
        const t = o.title, n = o.inProgress, r = o.description, l = o.inProgress, s = o.body, a = o.inProgress, c = o.tagInput, u = o.inProgress, d = o.inProgress;
        return t !== e._v$ && (i.value = e._v$ = t), n !== e._v$2 && (i.disabled = e._v$2 = n), 
        r !== e._v$3 && (f.value = e._v$3 = r), l !== e._v$4 && (f.disabled = e._v$4 = l), 
        s !== e._v$5 && (v.value = e._v$5 = s), a !== e._v$6 && (v.disabled = e._v$6 = a), 
        c !== e._v$7 && (p.value = e._v$7 = c), u !== e._v$8 && (p.disabled = e._v$8 = u), 
        d !== e._v$9 && (b.disabled = e._v$9 = d), e;
      }, {
        _v$: void 0,
        _v$2: void 0,
        _v$3: void 0,
        _v$4: void 0,
        _v$5: void 0,
        _v$6: void 0,
        _v$7: void 0,
        _v$8: void 0,
        _v$9: void 0
      }), e;
    })();
  }
});