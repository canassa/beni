# Style Guide


These coding conventions are not enforced by the compiler, but they are shipped in this documentation along with the compiler in order to provide a point of reference, should anyone wish to point to an authority on agreed upon Zig coding style.

### [Avoid Redundancy in Names](#toc-Avoid-Redundancy-in-Names) [§](#Avoid-Redundancy-in-Names)

Avoid these words in type names:

- Value
- Data
- Context
- Manager
- State
- utils, misc, or somebody's initials

Everything is a value, all types are data, everything is context, all logic manages state. Nothing is communicated by using a word that applies to all types.

Temptation to use "utilities", "miscellaneous", or somebody's initials is a failure to categorize, or more commonly, overcategorization. Such declarations can live at the root of a module that needs them with no namespace needed.

### [Avoid Redundant Names in Fully-Qualified Namespaces](#toc-Avoid-Redundant-Names-in-Fully-Qualified-Namespaces) [§](#Avoid-Redundant-Names-in-Fully-Qualified-Namespaces)

Every declaration is assigned a **fully qualified namespace** by the compiler, creating a tree structure. Choose names based on the fully-qualified namespace, and avoid redundant name segments.

    const std = @import("std");

    pub const json = struct {
        pub const JsonValue = union(enum) {
            number: f64,
            boolean: bool,
            // ...
        };
    };

    pub fn main() void {
        std.debug.print("{s}\n", .{@typeName(json.JsonValue)});
    }

redundant_fqn.zig

    $ zig build-exe redundant_fqn.zig
    $ ./redundant_fqn
    redundant_fqn.json.JsonValue

Shell

In this example, "json" is repeated in the fully-qualified namespace. The solution is to delete `Json` from `JsonValue`. In this example we have an empty struct named `json` but remember that files also act as part of the fully-qualified namespace.

This example is an exception to the rule specified in [Avoid Redundancy in Names](#Avoid-Redundancy-in-Names). The meaning of the type has been reduced to its core: it is a json value. The name cannot be any more specific without being incorrect.

### [Refrain from Underscore Prefixes](#toc-Refrain-from-Underscore-Prefixes) [§](#Refrain-from-Underscore-Prefixes)

In some programming languages, it is common to prefix identifiers with underscores `_like_this` to avoid keyword collisions, name collisions, or indicate additional metadata associated with usage of the identifier, such as: privacy, existence of complex data invariants, exclusion from semantic versioning, or context-specific type reflection meaning.

In Zig, there are no private fields, and this style guide recommends against pretending otherwise. Instead, fields should be named carefully based on their semantics and documentation should indicate how to use fields without violating data invariants. If a field is not subject to the same semantic versioning rules as everything else, the exception should be noted in the [Doc Comments](#Doc-Comments).

As for [type reflection](#typeInfo), it is less error prone and more maintainable to use the type system than to make field names meaningful.

Regarding name collisions, an underscore is insufficient to explain the difference between the two otherwise identical names. If there's no danger in getting them mixed up, then this guide recommends more verbose names at outer scopes and more abbreviated names at inner scopes.

Finally, keyword collisions are better avoided via [String Identifier Syntax](#String-Identifier-Syntax).

### [Whitespace](#toc-Whitespace) [§](#Whitespace)

- 4 space indentation
- Open braces on same line, unless you need to wrap.
- If a list of things is longer than 2, put each item on its own line and exercise the ability to put an extra comma at the end.
- Line length: aim for 100; use common sense.

### [Names](#toc-Names) [§](#Names)

Roughly speaking: `camelCaseFunctionName`, `TitleCaseTypeName`, `snake_case_variable_name`. More precisely:

- If `x` is a `struct` with 0 fields and is never meant to be instantiated then `x` is considered to be a "namespace" and should be `snake_case`.
- If `x` is a `type` or `type` alias then `x` should be `TitleCase`.
- If `x` is callable, and `x`'s return type is `type`, then `x` should be `TitleCase`.
- If `x` is otherwise callable, then `x` should be `camelCase`.
- Otherwise, `x` should be `snake_case`.

Acronyms, initialisms, proper nouns, or any other word that has capitalization rules in written English are subject to naming conventions just like any other word. Even acronyms that are only 2 letters long are subject to these conventions.

File names fall into two categories: types and namespaces. If the file (implicitly a struct) has top level fields, it should be named like any other struct with fields using `TitleCase`. Otherwise, it should use `snake_case`. Directory names should be `snake_case`.

These are general rules of thumb; if it makes sense to do something different, do what makes sense. For example, if there is an established convention such as `ENOENT`, follow the established convention.

### [Examples](#toc-Examples) [§](#Examples)

    const namespace_name = @import("dir_name/file_name.zig");
    const TypeName = @import("dir_name/TypeName.zig");
    var global_var: i32 = undefined;
    const const_name = 42;
    const PrimitiveTypeAlias = f32;

    const StructName = struct {
        field: i32,
    };
    const StructAlias = StructName;

    fn functionName(param_name: TypeName) void {
        var functionPointer = functionName;
        functionPointer();
        functionPointer = otherFunction;
        functionPointer();
    }
    const functionAlias = functionName;

    fn ListTemplateFunction(comptime ChildType: type, comptime fixed_size: usize) type {
        return List(ChildType, fixed_size);
    }

    fn ShortList(comptime T: type, comptime n: usize) type {
        return struct {
            field_name: [n]T,
            fn methodName() void {}
        };
    }

    // The word XML loses its casing when used in Zig identifiers.
    const xml_document =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<document>
        \\</document>
    ;
    const XmlParser = struct {
        field: i32,
    };

    // The initials BE (Big Endian) are just another word in Zig identifier names.
    fn readU32Be() u32 {}

style_example.zig

See the [Zig Standard Library](#Zig-Standard-Library) for more examples.

### [Doc Comment Guidance](#toc-Doc-Comment-Guidance) [§](#Doc-Comment-Guidance)

- Omit any information that is redundant based on the name of the thing being documented.
- Duplicating information onto multiple similar functions is encouraged because it helps IDEs and other tools provide better help text.
- Use the word **assume** to indicate invariants that cause *unchecked* [Illegal Behavior](#Illegal-Behavior) when violated.
- Use the word **assert** to indicate invariants that cause *safety-checked* [Illegal Behavior](#Illegal-Behavior) when violated.

