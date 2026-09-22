import * as _isTypeInt64_1 from "typia/lib/internal/_isTypeInt64";
import * as _accessExpressionAsString_1 from "typia/lib/internal/_accessExpressionAsString";
const __typia_transform__accessExpressionAsString = _accessExpressionAsString_1._accessExpressionAsString;
import * as _jsonStringifyNumber_1 from "typia/lib/internal/_jsonStringifyNumber";
import * as _jsonStringifyString_1 from "typia/lib/internal/_jsonStringifyString";
import * as _jsonStringifyTail_1 from "typia/lib/internal/_jsonStringifyTail";
import * as _validateReport_1 from "typia/lib/internal/_validateReport";
import typia from "typia";
export const validateWire = (input) => (() => {
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
export const validateProgram = (input) => (() => {
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
export const stringifyWire = (input) => (() => {
    const _so0 = input => `{${_jsonStringifyTail_1._jsonStringifyTail(`"user-id":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input["user-id"]))},"display-name":${_jsonStringifyString_1._jsonStringifyString(input["display-name"])},"email":${_jsonStringifyString_1._jsonStringifyString(input.email)},"age":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input.age))},"active":${String(input.active)},"score":${String(_jsonStringifyNumber_1._jsonStringifyNumber(input.score))},"role":${_jsonStringifyString_1._jsonStringifyString(input.role)},${undefined === input.nickname ? "" : `"nickname":${_jsonStringifyString_1._jsonStringifyString(input.nickname)},`}${Object.entries(input).map(([key, value]) => { if (undefined === value)
        return ""; if (["user-id", "display-name", "email", "age", "active", "score", "role", "nickname"].some(regular => regular === key))
        return ""; if (RegExp(/^(__beni_schema_never__(.*))/).test(key))
        return `${`${JSON.stringify(key)}:`}${undefined}`; return ""; }).filter(str => "" !== str).join(",")}`)}}`;
    return input => _so0(input);
})()(input);
