import * as _isTypeInt64_1 from "typia/lib/internal/_isTypeInt64";
import * as _accessExpressionAsString_1 from "typia/lib/internal/_accessExpressionAsString";
const __typia_transform__accessExpressionAsString = _accessExpressionAsString_1._accessExpressionAsString;
import * as _jsonStringifyNumber_1 from "typia/lib/internal/_jsonStringifyNumber";
import * as _jsonStringifyString_1 from "typia/lib/internal/_jsonStringifyString";
import * as _jsonStringifyTail_1 from "typia/lib/internal/_jsonStringifyTail";
import * as _jsonStringifyArray_1 from "typia/lib/internal/_jsonStringifyArray";
import * as _throwTypeGuardError_1 from "typia/lib/internal/_throwTypeGuardError";
import * as _validateReport_1 from "typia/lib/internal/_validateReport";
import typia from "typia";
export const validateFlatWire = (input) => (() => {
    const _io0 = (input, _exceptionable = true) => "number" === typeof input["user-id"] && (_isTypeInt64_1._isTypeInt64(input["user-id"]) && -9007199254740991 <= input["user-id"] && input["user-id"] <= 9007199254740991) && "string" === typeof input["display-name"] && "string" === typeof input.email && ("number" === typeof input.age && (_isTypeInt64_1._isTypeInt64(input.age) && -9007199254740991 <= input.age && input.age <= 9007199254740991)) && "boolean" === typeof input.active && ("number" === typeof input.score && Number.isFinite(input.score)) && "string" === typeof input.role && (!("nickname" in input) || "string" === typeof input.nickname) && Object.keys(input).every(key => {
        if (["user-id", "display-name", "email", "age", "active", "score", "role", "nickname"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _vo0 = (input, _path, _exceptionable = true) => ["number" === typeof input["user-id"] && (_isTypeInt64_1._isTypeInt64(input["user-id"]) || _report(_exceptionable, {
            path: _path + "[\"user-id\"]",
            expected: "number & Type<\"int64\">",
            value: input["user-id"]
        })) && (-9007199254740991 <= input["user-id"] || _report(_exceptionable, {
            path: _path + "[\"user-id\"]",
            expected: "number & Minimum<-9007199254740991>",
            value: input["user-id"]
        })) && (input["user-id"] <= 9007199254740991 || _report(_exceptionable, {
            path: _path + "[\"user-id\"]",
            expected: "number & Maximum<9007199254740991>",
            value: input["user-id"]
        })) || _report(_exceptionable, {
            path: _path + "[\"user-id\"]",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input["user-id"]
        }), "string" === typeof input["display-name"] || _report(_exceptionable, {
            path: _path + "[\"display-name\"]",
            expected: "string",
            value: input["display-name"]
        }), "string" === typeof input.email || _report(_exceptionable, {
            path: _path + ".email",
            expected: "string",
            value: input.email
        }), "number" === typeof input.age && (_isTypeInt64_1._isTypeInt64(input.age) || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Type<\"int64\">",
            value: input.age
        })) && (-9007199254740991 <= input.age || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Minimum<-9007199254740991>",
            value: input.age
        })) && (input.age <= 9007199254740991 || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Maximum<9007199254740991>",
            value: input.age
        })) || _report(_exceptionable, {
            path: _path + ".age",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input.age
        }), "boolean" === typeof input.active || _report(_exceptionable, {
            path: _path + ".active",
            expected: "boolean",
            value: input.active
        }), "number" === typeof input.score && Number.isFinite(input.score) || _report(_exceptionable, {
            path: _path + ".score",
            expected: "number",
            value: input.score
        }), "string" === typeof input.role || _report(_exceptionable, {
            path: _path + ".role",
            expected: "string",
            value: input.role
        }), !("nickname" in input) || ("string" === typeof input.nickname || _report(_exceptionable, {
            path: _path + ".nickname",
            expected: "string",
            value: input.nickname
        })), false === _exceptionable || Object.keys(input).map(key => {
            if (["user-id", "display-name", "email", "age", "active", "score", "role", "nickname"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const __is = (input, _exceptionable = true) => "object" === typeof input && null !== input && _io0(input, true);
    let errors;
    let _report;
    return input => {
        if (false === __is(input)) {
            errors = [];
            _report = _validateReport_1._validateReport(errors);
            ((input, _path, _exceptionable = true) => ("object" === typeof input && null !== input || _report(true, {
                path: _path + "",
                expected: "FlatWire",
                value: input
            })) && _vo0(input, _path + "", true) || _report(true, {
                path: _path + "",
                expected: "FlatWire",
                value: input
            }))(input, "$input", true);
            const success = 0 === errors.length;
            return success ? {
                success,
                data: input
            } : {
                success,
                errors,
                data: input
            };
        }
        return {
            success: true,
            data: input
        };
    };
})()(input);
export const validateFlatProgram = (input) => (() => {
    const _io0 = (input, _exceptionable = true) => "number" === typeof input.userId && (_isTypeInt64_1._isTypeInt64(input.userId) && -9007199254740991 <= input.userId && input.userId <= 9007199254740991) && "string" === typeof input.displayName && "string" === typeof input.email && ("number" === typeof input.age && (_isTypeInt64_1._isTypeInt64(input.age) && -9007199254740991 <= input.age && input.age <= 9007199254740991)) && "boolean" === typeof input.active && ("number" === typeof input.score && Number.isFinite(input.score)) && "string" === typeof input.role && (!("nickname" in input) || "string" === typeof input.nickname) && Object.keys(input).every(key => {
        if (["userId", "displayName", "email", "age", "active", "score", "role", "nickname"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _vo0 = (input, _path, _exceptionable = true) => ["number" === typeof input.userId && (_isTypeInt64_1._isTypeInt64(input.userId) || _report(_exceptionable, {
            path: _path + ".userId",
            expected: "number & Type<\"int64\">",
            value: input.userId
        })) && (-9007199254740991 <= input.userId || _report(_exceptionable, {
            path: _path + ".userId",
            expected: "number & Minimum<-9007199254740991>",
            value: input.userId
        })) && (input.userId <= 9007199254740991 || _report(_exceptionable, {
            path: _path + ".userId",
            expected: "number & Maximum<9007199254740991>",
            value: input.userId
        })) || _report(_exceptionable, {
            path: _path + ".userId",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input.userId
        }), "string" === typeof input.displayName || _report(_exceptionable, {
            path: _path + ".displayName",
            expected: "string",
            value: input.displayName
        }), "string" === typeof input.email || _report(_exceptionable, {
            path: _path + ".email",
            expected: "string",
            value: input.email
        }), "number" === typeof input.age && (_isTypeInt64_1._isTypeInt64(input.age) || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Type<\"int64\">",
            value: input.age
        })) && (-9007199254740991 <= input.age || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Minimum<-9007199254740991>",
            value: input.age
        })) && (input.age <= 9007199254740991 || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Maximum<9007199254740991>",
            value: input.age
        })) || _report(_exceptionable, {
            path: _path + ".age",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input.age
        }), "boolean" === typeof input.active || _report(_exceptionable, {
            path: _path + ".active",
            expected: "boolean",
            value: input.active
        }), "number" === typeof input.score && Number.isFinite(input.score) || _report(_exceptionable, {
            path: _path + ".score",
            expected: "number",
            value: input.score
        }), "string" === typeof input.role || _report(_exceptionable, {
            path: _path + ".role",
            expected: "string",
            value: input.role
        }), !("nickname" in input) || ("string" === typeof input.nickname || _report(_exceptionable, {
            path: _path + ".nickname",
            expected: "string",
            value: input.nickname
        })), false === _exceptionable || Object.keys(input).map(key => {
            if (["userId", "displayName", "email", "age", "active", "score", "role", "nickname"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const __is = (input, _exceptionable = true) => "object" === typeof input && null !== input && _io0(input, true);
    let errors;
    let _report;
    return input => {
        if (false === __is(input)) {
            errors = [];
            _report = _validateReport_1._validateReport(errors);
            ((input, _path, _exceptionable = true) => ("object" === typeof input && null !== input || _report(true, {
                path: _path + "",
                expected: "FlatProgram",
                value: input
            })) && _vo0(input, _path + "", true) || _report(true, {
                path: _path + "",
                expected: "FlatProgram",
                value: input
            }))(input, "$input", true);
            const success = 0 === errors.length;
            return success ? {
                success,
                data: input
            } : {
                success,
                errors,
                data: input
            };
        }
        return {
            success: true,
            data: input
        };
    };
})()(input);
export const validateListWire = (input) => (() => {
    const _io0 = (input, _exceptionable = true) => "number" === typeof input["user-id"] && (_isTypeInt64_1._isTypeInt64(input["user-id"]) && -9007199254740991 <= input["user-id"] && input["user-id"] <= 9007199254740991) && "string" === typeof input["display-name"] && "string" === typeof input.email && ("number" === typeof input.age && (_isTypeInt64_1._isTypeInt64(input.age) && -9007199254740991 <= input.age && input.age <= 9007199254740991)) && "boolean" === typeof input.active && ("number" === typeof input.score && Number.isFinite(input.score)) && "string" === typeof input.role && (!("nickname" in input) || "string" === typeof input.nickname) && Object.keys(input).every(key => {
        if (["user-id", "display-name", "email", "age", "active", "score", "role", "nickname"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _vo0 = (input, _path, _exceptionable = true) => ["number" === typeof input["user-id"] && (_isTypeInt64_1._isTypeInt64(input["user-id"]) || _report(_exceptionable, {
            path: _path + "[\"user-id\"]",
            expected: "number & Type<\"int64\">",
            value: input["user-id"]
        })) && (-9007199254740991 <= input["user-id"] || _report(_exceptionable, {
            path: _path + "[\"user-id\"]",
            expected: "number & Minimum<-9007199254740991>",
            value: input["user-id"]
        })) && (input["user-id"] <= 9007199254740991 || _report(_exceptionable, {
            path: _path + "[\"user-id\"]",
            expected: "number & Maximum<9007199254740991>",
            value: input["user-id"]
        })) || _report(_exceptionable, {
            path: _path + "[\"user-id\"]",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input["user-id"]
        }), "string" === typeof input["display-name"] || _report(_exceptionable, {
            path: _path + "[\"display-name\"]",
            expected: "string",
            value: input["display-name"]
        }), "string" === typeof input.email || _report(_exceptionable, {
            path: _path + ".email",
            expected: "string",
            value: input.email
        }), "number" === typeof input.age && (_isTypeInt64_1._isTypeInt64(input.age) || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Type<\"int64\">",
            value: input.age
        })) && (-9007199254740991 <= input.age || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Minimum<-9007199254740991>",
            value: input.age
        })) && (input.age <= 9007199254740991 || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Maximum<9007199254740991>",
            value: input.age
        })) || _report(_exceptionable, {
            path: _path + ".age",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input.age
        }), "boolean" === typeof input.active || _report(_exceptionable, {
            path: _path + ".active",
            expected: "boolean",
            value: input.active
        }), "number" === typeof input.score && Number.isFinite(input.score) || _report(_exceptionable, {
            path: _path + ".score",
            expected: "number",
            value: input.score
        }), "string" === typeof input.role || _report(_exceptionable, {
            path: _path + ".role",
            expected: "string",
            value: input.role
        }), !("nickname" in input) || ("string" === typeof input.nickname || _report(_exceptionable, {
            path: _path + ".nickname",
            expected: "string",
            value: input.nickname
        })), false === _exceptionable || Object.keys(input).map(key => {
            if (["user-id", "display-name", "email", "age", "active", "score", "role", "nickname"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const __is = (input, _exceptionable = true) => Array.isArray(input) && input.every((elem, _index1) => "object" === typeof elem && null !== elem && _io0(elem, true));
    let errors;
    let _report;
    return input => {
        if (false === __is(input)) {
            errors = [];
            _report = _validateReport_1._validateReport(errors);
            ((input, _path, _exceptionable = true) => (Array.isArray(input) || _report(true, {
                path: _path + "",
                expected: "Array<FlatWire>",
                value: input
            })) && input.map((elem, _index2) => ("object" === typeof elem && null !== elem || _report(true, {
                path: _path + "[" + _index2 + "]",
                expected: "FlatWire",
                value: elem
            })) && _vo0(elem, _path + "[" + _index2 + "]", true) || _report(true, {
                path: _path + "[" + _index2 + "]",
                expected: "FlatWire",
                value: elem
            })).every(flag => flag) || _report(true, {
                path: _path + "",
                expected: "Array<FlatWire>",
                value: input
            }))(input, "$input", true);
            const success = 0 === errors.length;
            return success ? {
                success,
                data: input
            } : {
                success,
                errors,
                data: input
            };
        }
        return {
            success: true,
            data: input
        };
    };
})()(input);
export const validateListProgram = (input) => (() => {
    const _io0 = (input, _exceptionable = true) => "number" === typeof input.userId && (_isTypeInt64_1._isTypeInt64(input.userId) && -9007199254740991 <= input.userId && input.userId <= 9007199254740991) && "string" === typeof input.displayName && "string" === typeof input.email && ("number" === typeof input.age && (_isTypeInt64_1._isTypeInt64(input.age) && -9007199254740991 <= input.age && input.age <= 9007199254740991)) && "boolean" === typeof input.active && ("number" === typeof input.score && Number.isFinite(input.score)) && "string" === typeof input.role && (!("nickname" in input) || "string" === typeof input.nickname) && Object.keys(input).every(key => {
        if (["userId", "displayName", "email", "age", "active", "score", "role", "nickname"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _vo0 = (input, _path, _exceptionable = true) => ["number" === typeof input.userId && (_isTypeInt64_1._isTypeInt64(input.userId) || _report(_exceptionable, {
            path: _path + ".userId",
            expected: "number & Type<\"int64\">",
            value: input.userId
        })) && (-9007199254740991 <= input.userId || _report(_exceptionable, {
            path: _path + ".userId",
            expected: "number & Minimum<-9007199254740991>",
            value: input.userId
        })) && (input.userId <= 9007199254740991 || _report(_exceptionable, {
            path: _path + ".userId",
            expected: "number & Maximum<9007199254740991>",
            value: input.userId
        })) || _report(_exceptionable, {
            path: _path + ".userId",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input.userId
        }), "string" === typeof input.displayName || _report(_exceptionable, {
            path: _path + ".displayName",
            expected: "string",
            value: input.displayName
        }), "string" === typeof input.email || _report(_exceptionable, {
            path: _path + ".email",
            expected: "string",
            value: input.email
        }), "number" === typeof input.age && (_isTypeInt64_1._isTypeInt64(input.age) || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Type<\"int64\">",
            value: input.age
        })) && (-9007199254740991 <= input.age || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Minimum<-9007199254740991>",
            value: input.age
        })) && (input.age <= 9007199254740991 || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Maximum<9007199254740991>",
            value: input.age
        })) || _report(_exceptionable, {
            path: _path + ".age",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input.age
        }), "boolean" === typeof input.active || _report(_exceptionable, {
            path: _path + ".active",
            expected: "boolean",
            value: input.active
        }), "number" === typeof input.score && Number.isFinite(input.score) || _report(_exceptionable, {
            path: _path + ".score",
            expected: "number",
            value: input.score
        }), "string" === typeof input.role || _report(_exceptionable, {
            path: _path + ".role",
            expected: "string",
            value: input.role
        }), !("nickname" in input) || ("string" === typeof input.nickname || _report(_exceptionable, {
            path: _path + ".nickname",
            expected: "string",
            value: input.nickname
        })), false === _exceptionable || Object.keys(input).map(key => {
            if (["userId", "displayName", "email", "age", "active", "score", "role", "nickname"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const __is = (input, _exceptionable = true) => Array.isArray(input) && input.every((elem, _index1) => "object" === typeof elem && null !== elem && _io0(elem, true));
    let errors;
    let _report;
    return input => {
        if (false === __is(input)) {
            errors = [];
            _report = _validateReport_1._validateReport(errors);
            ((input, _path, _exceptionable = true) => (Array.isArray(input) || _report(true, {
                path: _path + "",
                expected: "Array<FlatProgram>",
                value: input
            })) && input.map((elem, _index2) => ("object" === typeof elem && null !== elem || _report(true, {
                path: _path + "[" + _index2 + "]",
                expected: "FlatProgram",
                value: elem
            })) && _vo0(elem, _path + "[" + _index2 + "]", true) || _report(true, {
                path: _path + "[" + _index2 + "]",
                expected: "FlatProgram",
                value: elem
            })).every(flag => flag) || _report(true, {
                path: _path + "",
                expected: "Array<FlatProgram>",
                value: input
            }))(input, "$input", true);
            const success = 0 === errors.length;
            return success ? {
                success,
                data: input
            } : {
                success,
                errors,
                data: input
            };
        }
        return {
            success: true,
            data: input
        };
    };
})()(input);
export const validateUnionWire = (input) => (() => {
    const _ve0 = "(Closed<{ kind: \"count\"; count: SafeInt; }> | Closed<{ kind: \"point\"; x: number; y: number; }> | Closed<{ kind: \"text\"; text: string; }> | Closed<{ kind: \"user\"; user: FlatWire; }>)";
    const _ve1 = "(Closed<{ kind: \"user\"; user: FlatWire; }> | Closed<{ kind: \"count\"; count: SafeInt; }> | Closed<{ kind: \"text\"; text: string; }> | Closed<{ kind: \"point\"; x: number; y: number; }>)";
    const _io0 = (input, _exceptionable = true) => "user" === input.kind && ("object" === typeof input.user && null !== input.user && _io1(input.user, true && _exceptionable)) && Object.keys(input).every(key => {
        if (["kind", "user"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _io1 = (input, _exceptionable = true) => "number" === typeof input["user-id"] && (_isTypeInt64_1._isTypeInt64(input["user-id"]) && -9007199254740991 <= input["user-id"] && input["user-id"] <= 9007199254740991) && "string" === typeof input["display-name"] && "string" === typeof input.email && ("number" === typeof input.age && (_isTypeInt64_1._isTypeInt64(input.age) && -9007199254740991 <= input.age && input.age <= 9007199254740991)) && "boolean" === typeof input.active && ("number" === typeof input.score && Number.isFinite(input.score)) && "string" === typeof input.role && (!("nickname" in input) || "string" === typeof input.nickname) && Object.keys(input).every(key => {
        if (["user-id", "display-name", "email", "age", "active", "score", "role", "nickname"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _io2 = (input, _exceptionable = true) => "count" === input.kind && ("number" === typeof input.count && (_isTypeInt64_1._isTypeInt64(input.count) && -9007199254740991 <= input.count && input.count <= 9007199254740991)) && Object.keys(input).every(key => {
        if (["kind", "count"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _io3 = (input, _exceptionable = true) => "text" === input.kind && "string" === typeof input.text && Object.keys(input).every(key => {
        if (["kind", "text"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _io4 = (input, _exceptionable = true) => "point" === input.kind && ("number" === typeof input.x && Number.isFinite(input.x)) && ("number" === typeof input.y && Number.isFinite(input.y)) && Object.keys(input).every(key => {
        if (["kind", "x", "y"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _iu0 = (input, _exceptionable = true) => (() => {
        if ("user" === input.kind)
            return _io0(input, true && _exceptionable);
        else if ("count" === input.kind)
            return _io2(input, true && _exceptionable);
        else if ("text" === input.kind)
            return _io3(input, true && _exceptionable);
        else if ("point" === input.kind)
            return _io4(input, true && _exceptionable);
        else
            return false;
    })();
    const _vo0 = (input, _path, _exceptionable = true) => ["user" === input.kind || _report(_exceptionable, {
            path: _path + ".kind",
            expected: "\"user\"",
            value: input.kind
        }), ("object" === typeof input.user && null !== input.user || _report(_exceptionable, {
            path: _path + ".user",
            expected: "FlatWire",
            value: input.user
        })) && _vo1(input.user, _path + ".user", true && _exceptionable) || _report(_exceptionable, {
            path: _path + ".user",
            expected: "FlatWire",
            value: input.user
        }), false === _exceptionable || Object.keys(input).map(key => {
            if (["kind", "user"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const _vo1 = (input, _path, _exceptionable = true) => ["number" === typeof input["user-id"] && (_isTypeInt64_1._isTypeInt64(input["user-id"]) || _report(_exceptionable, {
            path: _path + "[\"user-id\"]",
            expected: "number & Type<\"int64\">",
            value: input["user-id"]
        })) && (-9007199254740991 <= input["user-id"] || _report(_exceptionable, {
            path: _path + "[\"user-id\"]",
            expected: "number & Minimum<-9007199254740991>",
            value: input["user-id"]
        })) && (input["user-id"] <= 9007199254740991 || _report(_exceptionable, {
            path: _path + "[\"user-id\"]",
            expected: "number & Maximum<9007199254740991>",
            value: input["user-id"]
        })) || _report(_exceptionable, {
            path: _path + "[\"user-id\"]",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input["user-id"]
        }), "string" === typeof input["display-name"] || _report(_exceptionable, {
            path: _path + "[\"display-name\"]",
            expected: "string",
            value: input["display-name"]
        }), "string" === typeof input.email || _report(_exceptionable, {
            path: _path + ".email",
            expected: "string",
            value: input.email
        }), "number" === typeof input.age && (_isTypeInt64_1._isTypeInt64(input.age) || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Type<\"int64\">",
            value: input.age
        })) && (-9007199254740991 <= input.age || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Minimum<-9007199254740991>",
            value: input.age
        })) && (input.age <= 9007199254740991 || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Maximum<9007199254740991>",
            value: input.age
        })) || _report(_exceptionable, {
            path: _path + ".age",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input.age
        }), "boolean" === typeof input.active || _report(_exceptionable, {
            path: _path + ".active",
            expected: "boolean",
            value: input.active
        }), "number" === typeof input.score && Number.isFinite(input.score) || _report(_exceptionable, {
            path: _path + ".score",
            expected: "number",
            value: input.score
        }), "string" === typeof input.role || _report(_exceptionable, {
            path: _path + ".role",
            expected: "string",
            value: input.role
        }), !("nickname" in input) || ("string" === typeof input.nickname || _report(_exceptionable, {
            path: _path + ".nickname",
            expected: "string",
            value: input.nickname
        })), false === _exceptionable || Object.keys(input).map(key => {
            if (["user-id", "display-name", "email", "age", "active", "score", "role", "nickname"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const _vo2 = (input, _path, _exceptionable = true) => ["count" === input.kind || _report(_exceptionable, {
            path: _path + ".kind",
            expected: "\"count\"",
            value: input.kind
        }), "number" === typeof input.count && (_isTypeInt64_1._isTypeInt64(input.count) || _report(_exceptionable, {
            path: _path + ".count",
            expected: "number & Type<\"int64\">",
            value: input.count
        })) && (-9007199254740991 <= input.count || _report(_exceptionable, {
            path: _path + ".count",
            expected: "number & Minimum<-9007199254740991>",
            value: input.count
        })) && (input.count <= 9007199254740991 || _report(_exceptionable, {
            path: _path + ".count",
            expected: "number & Maximum<9007199254740991>",
            value: input.count
        })) || _report(_exceptionable, {
            path: _path + ".count",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input.count
        }), false === _exceptionable || Object.keys(input).map(key => {
            if (["kind", "count"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const _vo3 = (input, _path, _exceptionable = true) => ["text" === input.kind || _report(_exceptionable, {
            path: _path + ".kind",
            expected: "\"text\"",
            value: input.kind
        }), "string" === typeof input.text || _report(_exceptionable, {
            path: _path + ".text",
            expected: "string",
            value: input.text
        }), false === _exceptionable || Object.keys(input).map(key => {
            if (["kind", "text"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const _vo4 = (input, _path, _exceptionable = true) => ["point" === input.kind || _report(_exceptionable, {
            path: _path + ".kind",
            expected: "\"point\"",
            value: input.kind
        }), "number" === typeof input.x && Number.isFinite(input.x) || _report(_exceptionable, {
            path: _path + ".x",
            expected: "number",
            value: input.x
        }), "number" === typeof input.y && Number.isFinite(input.y) || _report(_exceptionable, {
            path: _path + ".y",
            expected: "number",
            value: input.y
        }), false === _exceptionable || Object.keys(input).map(key => {
            if (["kind", "x", "y"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const _vu0 = (input, _path, _exceptionable = true) => (() => {
        if ("user" === input.kind)
            return _vo0(input, _path, true && _exceptionable);
        else if ("count" === input.kind)
            return _vo2(input, _path, true && _exceptionable);
        else if ("text" === input.kind)
            return _vo3(input, _path, true && _exceptionable);
        else if ("point" === input.kind)
            return _vo4(input, _path, true && _exceptionable);
        else
            return _report(_exceptionable, {
                path: _path,
                expected: _ve1,
                value: input
            });
    })();
    const __is = (input, _exceptionable = true) => Array.isArray(input) && input.every((elem, _index1) => "object" === typeof elem && null !== elem && _iu0(elem, true));
    let errors;
    let _report;
    return input => {
        if (false === __is(input)) {
            errors = [];
            _report = _validateReport_1._validateReport(errors);
            ((input, _path, _exceptionable = true) => (Array.isArray(input) || _report(true, {
                path: _path + "",
                expected: "Array<UnionWire>",
                value: input
            })) && input.map((elem, _index2) => ("object" === typeof elem && null !== elem || _report(true, {
                path: _path + "[" + _index2 + "]",
                expected: _ve0,
                value: elem
            })) && _vu0(elem, _path + "[" + _index2 + "]", true) || _report(true, {
                path: _path + "[" + _index2 + "]",
                expected: _ve0,
                value: elem
            })).every(flag => flag) || _report(true, {
                path: _path + "",
                expected: "Array<UnionWire>",
                value: input
            }))(input, "$input", true);
            const success = 0 === errors.length;
            return success ? {
                success,
                data: input
            } : {
                success,
                errors,
                data: input
            };
        }
        return {
            success: true,
            data: input
        };
    };
})()(input);
export const validateUnionProgram = (input) => (() => {
    const _ve0 = "(Closed<{ kind: \"count\"; count: SafeInt; }> | Closed<{ kind: \"point\"; x: number; y: number; }> | Closed<{ kind: \"text\"; text: string; }> | Closed<{ kind: \"user\"; user: FlatProgram; }>)";
    const _ve1 = "(Closed<{ kind: \"user\"; user: FlatProgram; }> | Closed<{ kind: \"count\"; count: SafeInt; }> | Closed<{ kind: \"text\"; text: string; }> | Closed<{ kind: \"point\"; x: number; y: number; }>)";
    const _io0 = (input, _exceptionable = true) => "user" === input.kind && ("object" === typeof input.user && null !== input.user && _io1(input.user, true && _exceptionable)) && Object.keys(input).every(key => {
        if (["kind", "user"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _io1 = (input, _exceptionable = true) => "number" === typeof input.userId && (_isTypeInt64_1._isTypeInt64(input.userId) && -9007199254740991 <= input.userId && input.userId <= 9007199254740991) && "string" === typeof input.displayName && "string" === typeof input.email && ("number" === typeof input.age && (_isTypeInt64_1._isTypeInt64(input.age) && -9007199254740991 <= input.age && input.age <= 9007199254740991)) && "boolean" === typeof input.active && ("number" === typeof input.score && Number.isFinite(input.score)) && "string" === typeof input.role && (!("nickname" in input) || "string" === typeof input.nickname) && Object.keys(input).every(key => {
        if (["userId", "displayName", "email", "age", "active", "score", "role", "nickname"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _io2 = (input, _exceptionable = true) => "count" === input.kind && ("number" === typeof input.count && (_isTypeInt64_1._isTypeInt64(input.count) && -9007199254740991 <= input.count && input.count <= 9007199254740991)) && Object.keys(input).every(key => {
        if (["kind", "count"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _io3 = (input, _exceptionable = true) => "text" === input.kind && "string" === typeof input.text && Object.keys(input).every(key => {
        if (["kind", "text"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _io4 = (input, _exceptionable = true) => "point" === input.kind && ("number" === typeof input.x && Number.isFinite(input.x)) && ("number" === typeof input.y && Number.isFinite(input.y)) && Object.keys(input).every(key => {
        if (["kind", "x", "y"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _iu0 = (input, _exceptionable = true) => (() => {
        if ("user" === input.kind)
            return _io0(input, true && _exceptionable);
        else if ("count" === input.kind)
            return _io2(input, true && _exceptionable);
        else if ("text" === input.kind)
            return _io3(input, true && _exceptionable);
        else if ("point" === input.kind)
            return _io4(input, true && _exceptionable);
        else
            return false;
    })();
    const _vo0 = (input, _path, _exceptionable = true) => ["user" === input.kind || _report(_exceptionable, {
            path: _path + ".kind",
            expected: "\"user\"",
            value: input.kind
        }), ("object" === typeof input.user && null !== input.user || _report(_exceptionable, {
            path: _path + ".user",
            expected: "FlatProgram",
            value: input.user
        })) && _vo1(input.user, _path + ".user", true && _exceptionable) || _report(_exceptionable, {
            path: _path + ".user",
            expected: "FlatProgram",
            value: input.user
        }), false === _exceptionable || Object.keys(input).map(key => {
            if (["kind", "user"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const _vo1 = (input, _path, _exceptionable = true) => ["number" === typeof input.userId && (_isTypeInt64_1._isTypeInt64(input.userId) || _report(_exceptionable, {
            path: _path + ".userId",
            expected: "number & Type<\"int64\">",
            value: input.userId
        })) && (-9007199254740991 <= input.userId || _report(_exceptionable, {
            path: _path + ".userId",
            expected: "number & Minimum<-9007199254740991>",
            value: input.userId
        })) && (input.userId <= 9007199254740991 || _report(_exceptionable, {
            path: _path + ".userId",
            expected: "number & Maximum<9007199254740991>",
            value: input.userId
        })) || _report(_exceptionable, {
            path: _path + ".userId",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input.userId
        }), "string" === typeof input.displayName || _report(_exceptionable, {
            path: _path + ".displayName",
            expected: "string",
            value: input.displayName
        }), "string" === typeof input.email || _report(_exceptionable, {
            path: _path + ".email",
            expected: "string",
            value: input.email
        }), "number" === typeof input.age && (_isTypeInt64_1._isTypeInt64(input.age) || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Type<\"int64\">",
            value: input.age
        })) && (-9007199254740991 <= input.age || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Minimum<-9007199254740991>",
            value: input.age
        })) && (input.age <= 9007199254740991 || _report(_exceptionable, {
            path: _path + ".age",
            expected: "number & Maximum<9007199254740991>",
            value: input.age
        })) || _report(_exceptionable, {
            path: _path + ".age",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input.age
        }), "boolean" === typeof input.active || _report(_exceptionable, {
            path: _path + ".active",
            expected: "boolean",
            value: input.active
        }), "number" === typeof input.score && Number.isFinite(input.score) || _report(_exceptionable, {
            path: _path + ".score",
            expected: "number",
            value: input.score
        }), "string" === typeof input.role || _report(_exceptionable, {
            path: _path + ".role",
            expected: "string",
            value: input.role
        }), !("nickname" in input) || ("string" === typeof input.nickname || _report(_exceptionable, {
            path: _path + ".nickname",
            expected: "string",
            value: input.nickname
        })), false === _exceptionable || Object.keys(input).map(key => {
            if (["userId", "displayName", "email", "age", "active", "score", "role", "nickname"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const _vo2 = (input, _path, _exceptionable = true) => ["count" === input.kind || _report(_exceptionable, {
            path: _path + ".kind",
            expected: "\"count\"",
            value: input.kind
        }), "number" === typeof input.count && (_isTypeInt64_1._isTypeInt64(input.count) || _report(_exceptionable, {
            path: _path + ".count",
            expected: "number & Type<\"int64\">",
            value: input.count
        })) && (-9007199254740991 <= input.count || _report(_exceptionable, {
            path: _path + ".count",
            expected: "number & Minimum<-9007199254740991>",
            value: input.count
        })) && (input.count <= 9007199254740991 || _report(_exceptionable, {
            path: _path + ".count",
            expected: "number & Maximum<9007199254740991>",
            value: input.count
        })) || _report(_exceptionable, {
            path: _path + ".count",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input.count
        }), false === _exceptionable || Object.keys(input).map(key => {
            if (["kind", "count"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const _vo3 = (input, _path, _exceptionable = true) => ["text" === input.kind || _report(_exceptionable, {
            path: _path + ".kind",
            expected: "\"text\"",
            value: input.kind
        }), "string" === typeof input.text || _report(_exceptionable, {
            path: _path + ".text",
            expected: "string",
            value: input.text
        }), false === _exceptionable || Object.keys(input).map(key => {
            if (["kind", "text"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const _vo4 = (input, _path, _exceptionable = true) => ["point" === input.kind || _report(_exceptionable, {
            path: _path + ".kind",
            expected: "\"point\"",
            value: input.kind
        }), "number" === typeof input.x && Number.isFinite(input.x) || _report(_exceptionable, {
            path: _path + ".x",
            expected: "number",
            value: input.x
        }), "number" === typeof input.y && Number.isFinite(input.y) || _report(_exceptionable, {
            path: _path + ".y",
            expected: "number",
            value: input.y
        }), false === _exceptionable || Object.keys(input).map(key => {
            if (["kind", "x", "y"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const _vu0 = (input, _path, _exceptionable = true) => (() => {
        if ("user" === input.kind)
            return _vo0(input, _path, true && _exceptionable);
        else if ("count" === input.kind)
            return _vo2(input, _path, true && _exceptionable);
        else if ("text" === input.kind)
            return _vo3(input, _path, true && _exceptionable);
        else if ("point" === input.kind)
            return _vo4(input, _path, true && _exceptionable);
        else
            return _report(_exceptionable, {
                path: _path,
                expected: _ve1,
                value: input
            });
    })();
    const __is = (input, _exceptionable = true) => Array.isArray(input) && input.every((elem, _index1) => "object" === typeof elem && null !== elem && _iu0(elem, true));
    let errors;
    let _report;
    return input => {
        if (false === __is(input)) {
            errors = [];
            _report = _validateReport_1._validateReport(errors);
            ((input, _path, _exceptionable = true) => (Array.isArray(input) || _report(true, {
                path: _path + "",
                expected: "Array<UnionProgram>",
                value: input
            })) && input.map((elem, _index2) => ("object" === typeof elem && null !== elem || _report(true, {
                path: _path + "[" + _index2 + "]",
                expected: _ve0,
                value: elem
            })) && _vu0(elem, _path + "[" + _index2 + "]", true) || _report(true, {
                path: _path + "[" + _index2 + "]",
                expected: _ve0,
                value: elem
            })).every(flag => flag) || _report(true, {
                path: _path + "",
                expected: "Array<UnionProgram>",
                value: input
            }))(input, "$input", true);
            const success = 0 === errors.length;
            return success ? {
                success,
                data: input
            } : {
                success,
                errors,
                data: input
            };
        }
        return {
            success: true,
            data: input
        };
    };
})()(input);
export const validateTreeWire = (input) => (() => {
    const _io0 = (input, _exceptionable = true, _vctx = {}) => (_vctx.io0 || (_vctx.io0 = new WeakSet())).has(input) ? true : (_vctx.io0.add(input), ("number" === typeof input.id && (_isTypeInt64_1._isTypeInt64(input.id) && -9007199254740991 <= input.id && input.id <= 9007199254740991) && "string" === typeof input.label && (Array.isArray(input.children) && input.children.every((elem, _index1) => "object" === typeof elem && null !== elem && _io0(elem, true && _exceptionable, _vctx))) && Object.keys(input).every(key => {
        if (["id", "label", "children"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    })) || (_vctx.io0.delete(input), false));
    const _vo0 = (input, _path, _exceptionable = true, _vctx = {}) => (_vctx.vo0 || (_vctx.vo0 = new WeakSet())).has(input) ? true : (_vctx.vo0.add(input), (["number" === typeof input.id && (_isTypeInt64_1._isTypeInt64(input.id) || _report(_exceptionable, {
            path: _path + ".id",
            expected: "number & Type<\"int64\">",
            value: input.id
        })) && (-9007199254740991 <= input.id || _report(_exceptionable, {
            path: _path + ".id",
            expected: "number & Minimum<-9007199254740991>",
            value: input.id
        })) && (input.id <= 9007199254740991 || _report(_exceptionable, {
            path: _path + ".id",
            expected: "number & Maximum<9007199254740991>",
            value: input.id
        })) || _report(_exceptionable, {
            path: _path + ".id",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input.id
        }), "string" === typeof input.label || _report(_exceptionable, {
            path: _path + ".label",
            expected: "string",
            value: input.label
        }), (Array.isArray(input.children) || _report(_exceptionable, {
            path: _path + ".children",
            expected: "Array<Tree>",
            value: input.children
        })) && input.children.map((elem, _index2) => ("object" === typeof elem && null !== elem || _report(_exceptionable, {
            path: _path + ".children[" + _index2 + "]",
            expected: "Tree",
            value: elem
        })) && _vo0(elem, _path + ".children[" + _index2 + "]", true && _exceptionable, _vctx) || _report(_exceptionable, {
            path: _path + ".children[" + _index2 + "]",
            expected: "Tree",
            value: elem
        })).every(flag => flag) || _report(_exceptionable, {
            path: _path + ".children",
            expected: "Array<Tree>",
            value: input.children
        }), false === _exceptionable || Object.keys(input).map(key => {
            if (["id", "label", "children"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag)) || (_vctx.vo0.delete(input), false));
    const __is = (input, _exceptionable = true, _vctx = {}) => "object" === typeof input && null !== input && _io0(input, true, _vctx);
    let errors;
    let _report;
    return input => {
        if (false === __is(input)) {
            errors = [];
            _report = _validateReport_1._validateReport(errors);
            ((input, _path, _exceptionable = true, _vctx = {}) => ("object" === typeof input && null !== input || _report(true, {
                path: _path + "",
                expected: "Tree",
                value: input
            })) && _vo0(input, _path + "", true, _vctx) || _report(true, {
                path: _path + "",
                expected: "Tree",
                value: input
            }))(input, "$input", true);
            const success = 0 === errors.length;
            return success ? {
                success,
                data: input
            } : {
                success,
                errors,
                data: input
            };
        }
        return {
            success: true,
            data: input
        };
    };
})()(input);
export const validateTreeProgram = (input) => (() => {
    const _io0 = (input, _exceptionable = true, _vctx = {}) => (_vctx.io0 || (_vctx.io0 = new WeakSet())).has(input) ? true : (_vctx.io0.add(input), ("number" === typeof input.id && (_isTypeInt64_1._isTypeInt64(input.id) && -9007199254740991 <= input.id && input.id <= 9007199254740991) && "string" === typeof input.label && (Array.isArray(input.children) && input.children.every((elem, _index1) => "object" === typeof elem && null !== elem && _io0(elem, true && _exceptionable, _vctx))) && Object.keys(input).every(key => {
        if (["id", "label", "children"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    })) || (_vctx.io0.delete(input), false));
    const _vo0 = (input, _path, _exceptionable = true, _vctx = {}) => (_vctx.vo0 || (_vctx.vo0 = new WeakSet())).has(input) ? true : (_vctx.vo0.add(input), (["number" === typeof input.id && (_isTypeInt64_1._isTypeInt64(input.id) || _report(_exceptionable, {
            path: _path + ".id",
            expected: "number & Type<\"int64\">",
            value: input.id
        })) && (-9007199254740991 <= input.id || _report(_exceptionable, {
            path: _path + ".id",
            expected: "number & Minimum<-9007199254740991>",
            value: input.id
        })) && (input.id <= 9007199254740991 || _report(_exceptionable, {
            path: _path + ".id",
            expected: "number & Maximum<9007199254740991>",
            value: input.id
        })) || _report(_exceptionable, {
            path: _path + ".id",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input.id
        }), "string" === typeof input.label || _report(_exceptionable, {
            path: _path + ".label",
            expected: "string",
            value: input.label
        }), (Array.isArray(input.children) || _report(_exceptionable, {
            path: _path + ".children",
            expected: "Array<Tree>",
            value: input.children
        })) && input.children.map((elem, _index2) => ("object" === typeof elem && null !== elem || _report(_exceptionable, {
            path: _path + ".children[" + _index2 + "]",
            expected: "Tree",
            value: elem
        })) && _vo0(elem, _path + ".children[" + _index2 + "]", true && _exceptionable, _vctx) || _report(_exceptionable, {
            path: _path + ".children[" + _index2 + "]",
            expected: "Tree",
            value: elem
        })).every(flag => flag) || _report(_exceptionable, {
            path: _path + ".children",
            expected: "Array<Tree>",
            value: input.children
        }), false === _exceptionable || Object.keys(input).map(key => {
            if (["id", "label", "children"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag)) || (_vctx.vo0.delete(input), false));
    const __is = (input, _exceptionable = true, _vctx = {}) => "object" === typeof input && null !== input && _io0(input, true, _vctx);
    let errors;
    let _report;
    return input => {
        if (false === __is(input)) {
            errors = [];
            _report = _validateReport_1._validateReport(errors);
            ((input, _path, _exceptionable = true, _vctx = {}) => ("object" === typeof input && null !== input || _report(true, {
                path: _path + "",
                expected: "Tree",
                value: input
            })) && _vo0(input, _path + "", true, _vctx) || _report(true, {
                path: _path + "",
                expected: "Tree",
                value: input
            }))(input, "$input", true);
            const success = 0 === errors.length;
            return success ? {
                success,
                data: input
            } : {
                success,
                errors,
                data: input
            };
        }
        return {
            success: true,
            data: input
        };
    };
})()(input);
export const validateTypeaheadWire = (input) => (() => {
    const _io0 = (input, _exceptionable = true) => Array.isArray(input.hits) && input.hits.every((elem, _index1) => "object" === typeof elem && null !== elem && _io1(elem, true && _exceptionable)) && ("number" === typeof input.total && (_isTypeInt64_1._isTypeInt64(input.total) && -9007199254740991 <= input.total && input.total <= 9007199254740991)) && Object.keys(input).every(key => {
        if (["hits", "total"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _io1 = (input, _exceptionable = true) => "string" === typeof input.hit_id && "string" === typeof input.title && Object.keys(input).every(key => {
        if (["hit_id", "title"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _vo0 = (input, _path, _exceptionable = true) => [(Array.isArray(input.hits) || _report(_exceptionable, {
            path: _path + ".hits",
            expected: "Array<TypeaheadHitWire>",
            value: input.hits
        })) && input.hits.map((elem, _index2) => ("object" === typeof elem && null !== elem || _report(_exceptionable, {
            path: _path + ".hits[" + _index2 + "]",
            expected: "TypeaheadHitWire",
            value: elem
        })) && _vo1(elem, _path + ".hits[" + _index2 + "]", true && _exceptionable) || _report(_exceptionable, {
            path: _path + ".hits[" + _index2 + "]",
            expected: "TypeaheadHitWire",
            value: elem
        })).every(flag => flag) || _report(_exceptionable, {
            path: _path + ".hits",
            expected: "Array<TypeaheadHitWire>",
            value: input.hits
        }), "number" === typeof input.total && (_isTypeInt64_1._isTypeInt64(input.total) || _report(_exceptionable, {
            path: _path + ".total",
            expected: "number & Type<\"int64\">",
            value: input.total
        })) && (-9007199254740991 <= input.total || _report(_exceptionable, {
            path: _path + ".total",
            expected: "number & Minimum<-9007199254740991>",
            value: input.total
        })) && (input.total <= 9007199254740991 || _report(_exceptionable, {
            path: _path + ".total",
            expected: "number & Maximum<9007199254740991>",
            value: input.total
        })) || _report(_exceptionable, {
            path: _path + ".total",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input.total
        }), false === _exceptionable || Object.keys(input).map(key => {
            if (["hits", "total"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const _vo1 = (input, _path, _exceptionable = true) => ["string" === typeof input.hit_id || _report(_exceptionable, {
            path: _path + ".hit_id",
            expected: "string",
            value: input.hit_id
        }), "string" === typeof input.title || _report(_exceptionable, {
            path: _path + ".title",
            expected: "string",
            value: input.title
        }), false === _exceptionable || Object.keys(input).map(key => {
            if (["hit_id", "title"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const __is = (input, _exceptionable = true) => "object" === typeof input && null !== input && _io0(input, true);
    let errors;
    let _report;
    return input => {
        if (false === __is(input)) {
            errors = [];
            _report = _validateReport_1._validateReport(errors);
            ((input, _path, _exceptionable = true) => ("object" === typeof input && null !== input || _report(true, {
                path: _path + "",
                expected: "TypeaheadWire",
                value: input
            })) && _vo0(input, _path + "", true) || _report(true, {
                path: _path + "",
                expected: "TypeaheadWire",
                value: input
            }))(input, "$input", true);
            const success = 0 === errors.length;
            return success ? {
                success,
                data: input
            } : {
                success,
                errors,
                data: input
            };
        }
        return {
            success: true,
            data: input
        };
    };
})()(input);
export const validateTypeaheadProgram = (input) => (() => {
    const _io0 = (input, _exceptionable = true) => Array.isArray(input.hits) && input.hits.every((elem, _index1) => "object" === typeof elem && null !== elem && _io1(elem, true && _exceptionable)) && ("number" === typeof input.total && (_isTypeInt64_1._isTypeInt64(input.total) && -9007199254740991 <= input.total && input.total <= 9007199254740991)) && Object.keys(input).every(key => {
        if (["hits", "total"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _io1 = (input, _exceptionable = true) => "string" === typeof input.id && "string" === typeof input.title && Object.keys(input).every(key => {
        if (["id", "title"].some(prop => key === prop))
            return true;
        const value = input[key];
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return false;
    });
    const _vo0 = (input, _path, _exceptionable = true) => [(Array.isArray(input.hits) || _report(_exceptionable, {
            path: _path + ".hits",
            expected: "Array<TypeaheadHitProgram>",
            value: input.hits
        })) && input.hits.map((elem, _index2) => ("object" === typeof elem && null !== elem || _report(_exceptionable, {
            path: _path + ".hits[" + _index2 + "]",
            expected: "TypeaheadHitProgram",
            value: elem
        })) && _vo1(elem, _path + ".hits[" + _index2 + "]", true && _exceptionable) || _report(_exceptionable, {
            path: _path + ".hits[" + _index2 + "]",
            expected: "TypeaheadHitProgram",
            value: elem
        })).every(flag => flag) || _report(_exceptionable, {
            path: _path + ".hits",
            expected: "Array<TypeaheadHitProgram>",
            value: input.hits
        }), "number" === typeof input.total && (_isTypeInt64_1._isTypeInt64(input.total) || _report(_exceptionable, {
            path: _path + ".total",
            expected: "number & Type<\"int64\">",
            value: input.total
        })) && (-9007199254740991 <= input.total || _report(_exceptionable, {
            path: _path + ".total",
            expected: "number & Minimum<-9007199254740991>",
            value: input.total
        })) && (input.total <= 9007199254740991 || _report(_exceptionable, {
            path: _path + ".total",
            expected: "number & Maximum<9007199254740991>",
            value: input.total
        })) || _report(_exceptionable, {
            path: _path + ".total",
            expected: "(number & Type<\"int64\"> & Minimum<-9007199254740991> & Maximum<9007199254740991>)",
            value: input.total
        }), false === _exceptionable || Object.keys(input).map(key => {
            if (["hits", "total"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const _vo1 = (input, _path, _exceptionable = true) => ["string" === typeof input.id || _report(_exceptionable, {
            path: _path + ".id",
            expected: "string",
            value: input.id
        }), "string" === typeof input.title || _report(_exceptionable, {
            path: _path + ".title",
            expected: "string",
            value: input.title
        }), false === _exceptionable || Object.keys(input).map(key => {
            if (["id", "title"].some(prop => key === prop))
                return true;
            const value = input[key];
            if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
                return (null !== value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                })) && (undefined === value || _report(_exceptionable, {
                    path: _path + __typia_transform__accessExpressionAsString(key),
                    expected: "undefined",
                    value: value
                }));
            return _report(_exceptionable, {
                path: _path + _accessExpressionAsString_1._accessExpressionAsString(key),
                expected: "undefined",
                value: value,
                description: [
                    `The property \`${key}\` is not defined in the object type.`,
                    "",
                    "Please remove the property next time."
                ].join("\n")
            });
        }).every(flag => flag)].every(flag => flag);
    const __is = (input, _exceptionable = true) => "object" === typeof input && null !== input && _io0(input, true);
    let errors;
    let _report;
    return input => {
        if (false === __is(input)) {
            errors = [];
            _report = _validateReport_1._validateReport(errors);
            ((input, _path, _exceptionable = true) => ("object" === typeof input && null !== input || _report(true, {
                path: _path + "",
                expected: "TypeaheadProgram",
                value: input
            })) && _vo0(input, _path + "", true) || _report(true, {
                path: _path + "",
                expected: "TypeaheadProgram",
                value: input
            }))(input, "$input", true);
            const success = 0 === errors.length;
            return success ? {
                success,
                data: input
            } : {
                success,
                errors,
                data: input
            };
        }
        return {
            success: true,
            data: input
        };
    };
})()(input);
export const stringifyFlatWire = (input) => (() => {
    const _so0 = input => `{${_jsonStringifyTail_1._jsonStringifyTail(`"user-id":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input["user-id"]))},"display-name":${_jsonStringifyString_1._jsonStringifyString(input["display-name"])},"email":${_jsonStringifyString_1._jsonStringifyString(input.email)},"age":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input.age))},"active":${String(input.active)},"score":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input.score))},"role":${_jsonStringifyString_1._jsonStringifyString(input.role)},${undefined === input.nickname ? "" : `"nickname":${_jsonStringifyString_1._jsonStringifyString(input.nickname)},`}${Object.entries(input).map(([key, value]) => { if (undefined === value)
        return ""; if (["user-id", "display-name", "email", "age", "active", "score", "role", "nickname"].some(regular => regular === key))
        return ""; if (RegExp(/^(__beni_schema_never__(.*))/).test(key))
        return `${`${JSON.stringify(key)}:`}${undefined}`; return ""; }).filter(str => "" !== str).join(",")}`)}}`;
    return input => _so0(input);
})()(input);
export const stringifyListWire = (input) => (() => {
    const _so0 = input => `{${_jsonStringifyTail_1._jsonStringifyTail(`"user-id":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input["user-id"]))},"display-name":${_jsonStringifyString_1._jsonStringifyString(input["display-name"])},"email":${_jsonStringifyString_1._jsonStringifyString(input.email)},"age":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input.age))},"active":${String(input.active)},"score":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input.score))},"role":${_jsonStringifyString_1._jsonStringifyString(input.role)},${undefined === input.nickname ? "" : `"nickname":${_jsonStringifyString_1._jsonStringifyString(input.nickname)},`}${Object.entries(input).map(([key, value]) => { if (undefined === value)
        return ""; if (["user-id", "display-name", "email", "age", "active", "score", "role", "nickname"].some(regular => regular === key))
        return ""; if (RegExp(/^(__beni_schema_never__(.*))/).test(key))
        return `${`${JSON.stringify(key)}:`}${undefined}`; return ""; }).filter(str => "" !== str).join(",")}`)}}`;
    return input => `[${_jsonStringifyArray_1._jsonStringifyArray(input, elem => _so0(elem))}]`;
})()(input);
export const stringifyUnionWire = (input) => (() => {
    const _so0 = input => `{${_jsonStringifyTail_1._jsonStringifyTail(`"kind":${"\"" + input.kind + "\""},"user":${_so1(input.user)},${Object.entries(input).map(([key, value]) => { if (undefined === value)
        return ""; if (["kind", "user"].some(regular => regular === key))
        return ""; if (RegExp(/^(__beni_schema_never__(.*))/).test(key))
        return `${`${JSON.stringify(key)}:`}${undefined}`; return ""; }).filter(str => "" !== str).join(",")}`)}}`;
    const _so1 = input => `{${_jsonStringifyTail_1._jsonStringifyTail(`"user-id":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input["user-id"]))},"display-name":${_jsonStringifyString_1._jsonStringifyString(input["display-name"])},"email":${_jsonStringifyString_1._jsonStringifyString(input.email)},"age":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input.age))},"active":${String(input.active)},"score":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input.score))},"role":${_jsonStringifyString_1._jsonStringifyString(input.role)},${undefined === input.nickname ? "" : `"nickname":${_jsonStringifyString_1._jsonStringifyString(input.nickname)},`}${Object.entries(input).map(([key, value]) => { if (undefined === value)
        return ""; if (["user-id", "display-name", "email", "age", "active", "score", "role", "nickname"].some(regular => regular === key))
        return ""; if (RegExp(/^(__beni_schema_never__(.*))/).test(key))
        return `${`${JSON.stringify(key)}:`}${undefined}`; return ""; }).filter(str => "" !== str).join(",")}`)}}`;
    const _so2 = input => `{${_jsonStringifyTail_1._jsonStringifyTail(`"kind":${"\"" + input.kind + "\""},"count":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input.count))},${Object.entries(input).map(([key, value]) => { if (undefined === value)
        return ""; if (["kind", "count"].some(regular => regular === key))
        return ""; if (RegExp(/^(__beni_schema_never__(.*))/).test(key))
        return `${`${JSON.stringify(key)}:`}${undefined}`; return ""; }).filter(str => "" !== str).join(",")}`)}}`;
    const _so3 = input => `{${_jsonStringifyTail_1._jsonStringifyTail(`"kind":${"\"" + input.kind + "\""},"text":${_jsonStringifyString_1._jsonStringifyString(input.text)},${Object.entries(input).map(([key, value]) => { if (undefined === value)
        return ""; if (["kind", "text"].some(regular => regular === key))
        return ""; if (RegExp(/^(__beni_schema_never__(.*))/).test(key))
        return `${`${JSON.stringify(key)}:`}${undefined}`; return ""; }).filter(str => "" !== str).join(",")}`)}}`;
    const _so4 = input => `{${_jsonStringifyTail_1._jsonStringifyTail(`"kind":${"\"" + input.kind + "\""},"x":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input.x))},"y":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input.y))},${Object.entries(input).map(([key, value]) => { if (undefined === value)
        return ""; if (["kind", "x", "y"].some(regular => regular === key))
        return ""; if (RegExp(/^(__beni_schema_never__(.*))/).test(key))
        return `${`${JSON.stringify(key)}:`}${undefined}`; return ""; }).filter(str => "" !== str).join(",")}`)}}`;
    const _su0 = input => (() => {
        if ("user" === input.kind)
            return _so0(input);
        else if ("count" === input.kind)
            return _so2(input);
        else if ("text" === input.kind)
            return _so3(input);
        else if ("point" === input.kind)
            return _so4(input);
        else
            _throwTypeGuardError_1._throwTypeGuardError({
                method: "typia.json.stringify",
                expected: "(Closed<{ kind: \"user\"; user: FlatWire; }> | Closed<{ kind: \"count\"; count: SafeInt; }> | Closed<{ kind: \"text\"; text: string; }> | Closed<{ kind: \"point\"; x: number; y: number; }>)",
                value: input
            });
    })();
    const _io0 = input => "user" === input.kind && ("object" === typeof input.user && null !== input.user && _io1(input.user)) && Object.keys(input).every(key => {
        if (["kind", "user"].some(prop => key === prop))
            return true;
        const value = input[key];
        if (undefined === value)
            return true;
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return true;
    });
    const _io1 = input => "number" === typeof input["user-id"] && (_isTypeInt64_1._isTypeInt64(input["user-id"]) && -9007199254740991 <= input["user-id"] && input["user-id"] <= 9007199254740991) && "string" === typeof input["display-name"] && "string" === typeof input.email && ("number" === typeof input.age && (_isTypeInt64_1._isTypeInt64(input.age) && -9007199254740991 <= input.age && input.age <= 9007199254740991)) && "boolean" === typeof input.active && "number" === typeof input.score && "string" === typeof input.role && (!("nickname" in input) || "string" === typeof input.nickname) && Object.keys(input).every(key => {
        if (["user-id", "display-name", "email", "age", "active", "score", "role", "nickname"].some(prop => key === prop))
            return true;
        const value = input[key];
        if (undefined === value)
            return true;
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return true;
    });
    const _io2 = input => "count" === input.kind && ("number" === typeof input.count && (_isTypeInt64_1._isTypeInt64(input.count) && -9007199254740991 <= input.count && input.count <= 9007199254740991)) && Object.keys(input).every(key => {
        if (["kind", "count"].some(prop => key === prop))
            return true;
        const value = input[key];
        if (undefined === value)
            return true;
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return true;
    });
    const _io3 = input => "text" === input.kind && "string" === typeof input.text && Object.keys(input).every(key => {
        if (["kind", "text"].some(prop => key === prop))
            return true;
        const value = input[key];
        if (undefined === value)
            return true;
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return true;
    });
    const _io4 = input => "point" === input.kind && "number" === typeof input.x && "number" === typeof input.y && Object.keys(input).every(key => {
        if (["kind", "x", "y"].some(prop => key === prop))
            return true;
        const value = input[key];
        if (undefined === value)
            return true;
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return true;
    });
    return input => `[${_jsonStringifyArray_1._jsonStringifyArray(input, elem => _su0(elem))}]`;
})()(input);
export const stringifyTreeWire = (input) => (() => {
    const _so0 = (input, _vctx = {}) => (_vctx.so0 || (_vctx.so0 = new WeakSet())).has(input) ? _throwTypeGuardError_1._throwTypeGuardError({
        method: "typia.json.stringify",
        expected: "non-circular reference",
        value: input
    }) : (_vctx.so0.add(input), (_vout => (_vctx.so0.delete(input), _vout))(`{${_jsonStringifyTail_1._jsonStringifyTail(`"id":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input.id))},"label":${_jsonStringifyString_1._jsonStringifyString(input.label)},"children":${`[${_jsonStringifyArray_1._jsonStringifyArray(input.children, elem => _so0(elem, _vctx))}]`},${Object.entries(input).map(([key, value]) => { if (undefined === value)
        return ""; if (["id", "label", "children"].some(regular => regular === key))
        return ""; if (RegExp(/^(__beni_schema_never__(.*))/).test(key))
        return `${`${JSON.stringify(key)}:`}${undefined}`; return ""; }).filter(str => "" !== str).join(",")}`)}}`));
    const _io0 = (input, _vctx = {}) => (_vctx.io0 || (_vctx.io0 = new WeakSet())).has(input) ? true : (_vctx.io0.add(input), ("number" === typeof input.id && (_isTypeInt64_1._isTypeInt64(input.id) && -9007199254740991 <= input.id && input.id <= 9007199254740991) && "string" === typeof input.label && (Array.isArray(input.children) && input.children.every(elem => "object" === typeof elem && null !== elem && _io0(elem, _vctx))) && Object.keys(input).every(key => {
        if (["id", "label", "children"].some(prop => key === prop))
            return true;
        const value = input[key];
        if (undefined === value)
            return true;
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return true;
    })) || (_vctx.io0.delete(input), false));
    return (input, _vctx = {}) => _so0(input, _vctx);
})()(input);
export const stringifyTypeaheadWire = (input) => (() => {
    const _so0 = input => `{${_jsonStringifyTail_1._jsonStringifyTail(`"hits":${`[${_jsonStringifyArray_1._jsonStringifyArray(input.hits, elem => _so1(elem))}]`},"total":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input.total))},${Object.entries(input).map(([key, value]) => { if (undefined === value)
        return ""; if (["hits", "total"].some(regular => regular === key))
        return ""; if (RegExp(/^(__beni_schema_never__(.*))/).test(key))
        return `${`${JSON.stringify(key)}:`}${undefined}`; return ""; }).filter(str => "" !== str).join(",")}`)}}`;
    const _so1 = input => `{${_jsonStringifyTail_1._jsonStringifyTail(`"hit_id":${_jsonStringifyString_1._jsonStringifyString(input.hit_id)},"title":${_jsonStringifyString_1._jsonStringifyString(input.title)},${Object.entries(input).map(([key, value]) => { if (undefined === value)
        return ""; if (["hit_id", "title"].some(regular => regular === key))
        return ""; if (RegExp(/^(__beni_schema_never__(.*))/).test(key))
        return `${`${JSON.stringify(key)}:`}${undefined}`; return ""; }).filter(str => "" !== str).join(",")}`)}}`;
    const _io1 = input => "string" === typeof input.hit_id && "string" === typeof input.title && Object.keys(input).every(key => {
        if (["hit_id", "title"].some(prop => key === prop))
            return true;
        const value = input[key];
        if (undefined === value)
            return true;
        if ("string" === typeof key && RegExp(/^__beni_schema_never__(.*)/).test(key))
            return null !== value && undefined === value;
        return true;
    });
    return input => _so0(input);
})()(input);
