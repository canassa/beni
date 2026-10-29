// QuickJS's parser needs a NUL after the source.
static const unsigned char prelude_js[] = {
#embed "prelude.js"
    , 0
};
#define prelude_js_len (sizeof(prelude_js) - 1)
