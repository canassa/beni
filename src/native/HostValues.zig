// ownership pin begin: host_append
// ownership pin begin: host_asAnchor
// ownership pin begin: host_asElement
// ownership pin begin: host_asForm
// ownership pin begin: host_asInput
// ownership pin begin: host_asNode
// ownership pin begin: host_asOption
// ownership pin begin: host_asSelect
// ownership pin begin: host_asTextArea
// ownership pin begin: host_code
// ownership pin begin: host_dataOnly
// ownership pin begin: host_error
// ownership pin begin: host_errorMessage
// ownership pin begin: host_querySelector
// ownership pin begin: host_getAttribute
// ownership pin begin: host_get
// ownership pin begin: host_group
// ownership pin begin: host_init
// ownership pin begin: host_key
// ownership pin begin: host_onText
// ownership pin begin: host_post
// ownership pin begin: host_reader
// ownership pin begin: host_selectionDirection
// ownership pin begin: host_selectionEnd
// ownership pin begin: host_selectionStart
// ownership pin begin: host_set
// ownership pin begin: host_setSelectionRange
// ownership pin begin: host_setValue
// ownership pin begin: host_target
// ownership pin begin: host_typeErrorMessage
// ownership pin begin: host_value
//! Reviewed typed host projections. The compiler maps documented absence
//! to Js.Opt; generated beni wrappers alone construct Maybe and Result.

pub const Mode = enum { passthrough, null_value, undefined_value, nullish, unit_result, syntax_result, worker_result, query_result, checked_data };
pub const Adapter = struct { signature: []const u8, wrapper: []const u8, mode: Mode };

pub fn get(recipe: anytype) ?Adapter {
    return switch (recipe) {
        .event_target => .{ .signature = "aliased Event → Js.Opt EventTarget.EventTarget", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .null_value },
        .target_node => .{ .signature = "aliased EventTarget → Js.Opt Node.Node", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .node_element => .{ .signature = "aliased EventTarget → Js.Opt Element.Element", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .element_as_input => .{ .signature = "aliased EventTarget → Js.Opt HTMLInputElement.HTMLInputElement", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .input_value_set => .{ .signature = "borrowed HTMLInputElement, String → Js.Opt ⊤", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Err InvalidStateError) λpresent →\n    Ok present", .mode = .unit_result },
        .input_selectionStart => .{ .signature = "borrowed HTMLInputElement → Js.Opt Int", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .null_value },
        .input_selectionEnd => .{ .signature = "borrowed HTMLInputElement → Js.Opt Int", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .null_value },
        .input_selectionDirection => .{ .signature = "borrowed HTMLInputElement → Js.Opt String", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent →\n    Just present", .mode = .null_value },
        .input_selection_set => .{ .signature = "\n      borrowed HTMLInputElement\n    , Int\n    , Int\n    , String\n    → Js.Opt ⊤", .wrapper = "NAME a0 a1 a2 a3 =\n    Js.optMatch (host_NAME a0 a1 a2 a3) (λ⊤ → Err InvalidStateError) λpresent →\n        Ok present", .mode = .unit_result },
        .element_as_textarea => .{ .signature = "\n      aliased EventTarget\n    → Js.Opt HTMLTextAreaElement.HTMLTextAreaElement", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .element_as_select => .{ .signature = "aliased EventTarget → Js.Opt HTMLSelectElement.HTMLSelectElement", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .element_as_option => .{ .signature = "aliased EventTarget → Js.Opt HTMLOptionElement.HTMLOptionElement", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .element_as_form => .{ .signature = "aliased EventTarget → Js.Opt HTMLFormElement.HTMLFormElement", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .document_active => .{ .signature = "⊤ → Js.Opt Element.Element", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .null_value },
        .event_error_message => .{ .signature = "borrowed Event → Js.Opt String", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .regexp_group => .{ .signature = "borrowed RegExp, String, Int → Js.Opt String", .wrapper = "NAME a0 a1 a2 = Js.optMatch (host_NAME a0 a1 a2) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .map_get => .{ .signature = "Map String a, String → a", .wrapper = "NAME a0 a1 =\n    if has a0 a1 then\n        Just (host_NAME a0 a1)\n    else\n        Nothing", .mode = .passthrough },
        .cf_instance => .{ .signature = "\n      sync (Request.Request → Promise.Promise Response.Response)\n    , sync (⊤ → Promise.Promise ⊤)\n    , sync (Js.Opt String, String, Js.Opt String, String → Promise.Promise Js.Value)\n    , sync (Socket, Js.Opt String → Promise.Promise ⊤)\n    , sync (Socket, Int, String, Bool → Promise.Promise ⊤)\n    , sync (Socket, Rejection.Rejection → Promise.Promise ⊤)\n    → Instance", .wrapper = "NAME a0 a1 a2 a3 a4 a5 =\n    host_NAME\n        a0\n        a1\n        (λchain kind id text →\n            a2\n                (Js.optMatch chain (λ⊤ → Nothing) λpresent → Just present)\n                kind\n                (Js.optMatch id (λ⊤ → Nothing) λpresent → Just present)\n                text\n        )\n        (λsocket text → a3 socket (Js.optMatch text (λ⊤ → Nothing) λpresent → Just present))\n        a4\n        a5", .mode = .passthrough },
        .cf_namespace => .{ .signature = "Env, String → Js.Opt Namespace", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .cf_service => .{ .signature = "Env, String → Js.Opt Service", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .cf_variable => .{ .signature = "Env, String → Js.Opt String", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .cf_idFromString => .{ .signature = "Namespace, String → Js.Opt Id", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .cf_idName => .{ .signature = "Id → Js.Opt String", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .nullish },
        .cf_requestSignal => .{ .signature = "Request.Request → Js.Opt AbortSignal.AbortSignal", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .nullish },
        .cf_kv => .{ .signature = "ObjectState → Js.Opt KV", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .nullish },
        .cf_kvGet => .{ .signature = "KV, String → Js.Opt String", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Nothing) λpresent → Just present", .mode = .nullish },
        .worker_create => .{ .signature = "String, String, String → Js.Opt (Js.Opt (Js.Opt Worker))", .wrapper = "NAME a0 a1 a2 = Js.optMatch (host_NAME a0 a1 a2) (λ⊤ → Err SyntaxError) λsecurity →\n    Js.optMatch security (λ⊤ → Err SecurityError) λinvalid →\n        Js.optMatch invalid (λ⊤ → Err TypeError) λpresent → Ok present", .mode = .worker_result },
        .worker_post => .{ .signature = "borrowed Endpoint, Js.Value → Js.Opt ⊤", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Err DataCloneError) λpresent → Ok present", .mode = .unit_result },
        .key_map_get => .{ .signature = "borrowed Map key value, borrowed key → value", .wrapper = "NAME a0 a1 =\n    if has a0 a1 then\n        Just (host_NAME a0 a1)\n    else\n        Nothing", .mode = .passthrough },
        .document_body => .{ .signature = "⊤ → Js.Opt Element.Element", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .null_value },
        .node_append => .{ .signature = "borrowed Node, borrowed Node → Js.Opt ⊤", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Err HierarchyRequestError) λpresent →\n    Ok present", .mode = .unit_result },
        .event_error => .{ .signature = "aliased Event → Js.Opt Rejection.Rejection", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .nullish },
        .document_by_id => .{ .signature = "String → Js.Opt Element.Element", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .null_value },
        .document_fullscreen_id => .{ .signature = "⊤ → Js.Opt String", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent →\n    Just present", .mode = .undefined_value },
        .rejection_type_error_message => .{ .signature = "borrowed Rejection → Js.Opt String", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .ws_create => .{ .signature = "String, List String → Js.Opt WebSocket", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .ws_message => .{ .signature = "borrowed WebSocket, escaped sync (Js.Opt String → ⊤) → ⊤", .wrapper = "NAME a0 a1 = host_NAME a0 λtext → a1 (Js.optMatch text (λ⊤ → Nothing) λpresent → Just present)", .mode = .passthrough },
        .storage_local => .{ .signature = "⊤ → Js.Opt Storage", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .nullish },
        .storage_session => .{ .signature = "⊤ → Js.Opt Storage", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .nullish },
        .storage_get => .{ .signature = "borrowed Storage, String → Js.Opt String", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Nothing) λpresent → Just present", .mode = .null_value },
        .storage_set => .{ .signature = "borrowed Storage, String, String → Js.Opt ⊤", .wrapper = "NAME a0 a1 a2 = Js.optMatch (host_NAME a0 a1 a2) (λ⊤ → Err QuotaExceeded) λpresent → Ok present", .mode = .unit_result },
        .storage_key => .{ .signature = "borrowed Storage, Int → Js.Opt String", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Nothing) λpresent → Just present", .mode = .null_value },
        .url_try_create => .{ .signature = "String, String → Js.Opt URL", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Nothing) λpresent → Just present", .mode = .nullish },
        .headers_get => .{ .signature = "borrowed Headers, String → Js.Opt String", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Nothing) λpresent → Just present", .mode = .null_value },
        .response_reader => .{ .signature = "\n      aliased Response\n    → Js.Opt ReadableStreamDefaultReader.ReadableStreamDefaultReader", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .null_value },
        .read_result_value => .{ .signature = "aliased ReadResult → Js.Opt Uint8Array.Uint8Array", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .regexp_create => .{ .signature = "String, String → Js.Opt RegExp", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Err SyntaxError) λpresent → Ok present", .mode = .syntax_result },
        .json_parse => .{ .signature = "String → Js.Opt Js.Value", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Err SyntaxError) λpresent → Ok present", .mode = .syntax_result },
        .rejection_code => .{ .signature = "borrowed Rejection → Js.Opt String", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .as_anchor => .{ .signature = "aliased EventTarget → Js.Opt HTMLAnchorElement.HTMLAnchorElement", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .undefined_value },
        .query_selector => .{ .signature = "Document, String → Js.Opt (Js.Opt Element.Element)", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Err SyntaxError) λselected →\n    Ok (Js.optMatch selected (λ⊤ → Nothing) λpresent → Just present)", .mode = .query_result },
        .element_query => .{ .signature = "borrowed Element, String → Js.Opt (Js.Opt Element)", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Err SyntaxError) λselected →\n    Ok (Js.optMatch selected (λ⊤ → Nothing) λpresent → Just present)", .mode = .query_result },
        .element_get_attribute => .{ .signature = "borrowed Element, String → Js.Opt String", .wrapper = "NAME a0 a1 = Js.optMatch (host_NAME a0 a1) (λ⊤ → Nothing) λpresent → Just present", .mode = .null_value },
        .text_content => .{ .signature = "Node → Js.Opt String", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .null_value },
        .cf_responseCreate => .{ .signature = "Int, Js.Opt String, List (String × String) → Response.Response", .wrapper = "NAME a0 a1 a2 =\n    optional =\n        case a1 of\n            Nothing →\n                Js.none ⊤\n            Just present →\n                Js.some present\n    host_NAME a0 optional a2", .mode = .passthrough },
        .cf_stubRpc => .{ .signature = "Stub, String, String, Js.Opt String, String → Promise.Promise Js.Value", .wrapper = "NAME a0 a1 a2 a3 a4 =\n    optional =\n        case a3 of\n            Nothing →\n                Js.none ⊤\n            Just present →\n                Js.some present\n    host_NAME a0 a1 a2 optional a4", .mode = .passthrough },
        .fetch_init => .{ .signature = "\n      String\n    , aliased Headers.Headers\n    , Js.Opt Body\n    , aliased AbortSignal.AbortSignal\n    , String\n    → Init", .wrapper = "NAME a0 a1 a2 a3 a4 =\n    optional =\n        case a2 of\n            Nothing →\n                Js.none ⊤\n            Just present →\n                Js.some present\n    host_NAME a0 a1 optional a3 a4", .mode = .passthrough },
        .event_data_only => .{ .signature = "aliased Event → Js.Opt Js.Value", .wrapper = "NAME a0 = Js.optMatch (host_NAME a0) (λ⊤ → Nothing) λpresent → Just present", .mode = .checked_data },
        else => null,
    };
}

// ownership pin end: host_append
// ownership pin end: host_asAnchor
// ownership pin end: host_asElement
// ownership pin end: host_asForm
// ownership pin end: host_asInput
// ownership pin end: host_asNode
// ownership pin end: host_asOption
// ownership pin end: host_asSelect
// ownership pin end: host_asTextArea
// ownership pin end: host_code
// ownership pin end: host_dataOnly
// ownership pin end: host_error
// ownership pin end: host_errorMessage
// ownership pin end: host_get
// ownership pin end: host_getAttribute
// ownership pin end: host_querySelector
// ownership pin end: host_group
// ownership pin end: host_init
// ownership pin end: host_key
// ownership pin end: host_onText
// ownership pin end: host_post
// ownership pin end: host_reader
// ownership pin end: host_selectionDirection
// ownership pin end: host_selectionEnd
// ownership pin end: host_selectionStart
// ownership pin end: host_set
// ownership pin end: host_setSelectionRange
// ownership pin end: host_setValue
// ownership pin end: host_target
// ownership pin end: host_typeErrorMessage
// ownership pin end: host_value
