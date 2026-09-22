import typia, { type IValidation, type tags } from "typia";

type SafeInt = number
    & tags.Type<"int64">
    & tags.Minimum<-9007199254740991>
    & tags.Maximum<9007199254740991>;
// A never-valued template index keeps validateEquals on its native per-key
// diagnostic path. Without a dynamic signature Typia first checks key count;
// an object with every optional property plus one surplus key then receives
// only the parent path. This signature accepts no additional value and does not
// weaken validation; it disables that lossy count shortcut in generated code.
type Closed<T> = T & { [key: `__beni_schema_never__${string}`]: never };

export interface FlatWire {
    [key: `__beni_schema_never__${string}`]: never;
    "user-id": SafeInt;
    "display-name": string;
    email: string;
    age: SafeInt;
    active: boolean;
    score: number;
    role: string;
    nickname?: string;
}

export interface FlatProgram {
    [key: `__beni_schema_never__${string}`]: never;
    userId: SafeInt;
    displayName: string;
    email: string;
    age: SafeInt;
    active: boolean;
    score: number;
    role: string;
    nickname?: string;
}

export type UnionWire =
    | Closed<{ kind: "user"; user: FlatWire }>
    | Closed<{ kind: "count"; count: SafeInt }>
    | Closed<{ kind: "text"; text: string }>
    | Closed<{ kind: "point"; x: number; y: number }>;

export type UnionProgram =
    | Closed<{ kind: "user"; user: FlatProgram }>
    | Closed<{ kind: "count"; count: SafeInt }>
    | Closed<{ kind: "text"; text: string }>
    | Closed<{ kind: "point"; x: number; y: number }>;

export interface Tree {
    [key: `__beni_schema_never__${string}`]: never;
    id: SafeInt;
    label: string;
    children: Tree[];
}

interface TypeaheadHitWire {
    [key: `__beni_schema_never__${string}`]: never;
    hit_id: string;
    title: string;
}

interface TypeaheadHitProgram {
    [key: `__beni_schema_never__${string}`]: never;
    id: string;
    title: string;
}

export interface TypeaheadWire {
    [key: `__beni_schema_never__${string}`]: never;
    hits: TypeaheadHitWire[];
    total: SafeInt;
}

export interface TypeaheadProgram {
    [key: `__beni_schema_never__${string}`]: never;
    hits: TypeaheadHitProgram[];
    total: SafeInt;
}

export const validateFlatWire = (input: unknown): IValidation<FlatWire> =>
    typia.validateEquals<FlatWire>(input);
export const validateFlatProgram = (input: unknown): IValidation<FlatProgram> =>
    typia.validateEquals<FlatProgram>(input);
export const validateListWire = (input: unknown): IValidation<FlatWire[]> =>
    typia.validateEquals<FlatWire[]>(input);
export const validateListProgram = (input: unknown): IValidation<FlatProgram[]> =>
    typia.validateEquals<FlatProgram[]>(input);
export const validateUnionWire = (input: unknown): IValidation<UnionWire[]> =>
    typia.validateEquals<UnionWire[]>(input);
export const validateUnionProgram = (input: unknown): IValidation<UnionProgram[]> =>
    typia.validateEquals<UnionProgram[]>(input);
export const validateTreeWire = (input: unknown): IValidation<Tree> =>
    typia.validateEquals<Tree>(input);
export const validateTreeProgram = (input: unknown): IValidation<Tree> =>
    typia.validateEquals<Tree>(input);
export const validateTypeaheadWire = (input: unknown): IValidation<TypeaheadWire> =>
    typia.validateEquals<TypeaheadWire>(input);
export const validateTypeaheadProgram = (input: unknown): IValidation<TypeaheadProgram> =>
    typia.validateEquals<TypeaheadProgram>(input);

export const stringifyFlatWire = (input: FlatWire): string =>
    typia.json.stringify<FlatWire>(input);
export const stringifyListWire = (input: FlatWire[]): string =>
    typia.json.stringify<FlatWire[]>(input);
export const stringifyUnionWire = (input: UnionWire[]): string =>
    typia.json.stringify<UnionWire[]>(input);
export const stringifyTreeWire = (input: Tree): string =>
    typia.json.stringify<Tree>(input);
export const stringifyTypeaheadWire = (input: TypeaheadWire): string =>
    typia.json.stringify<TypeaheadWire>(input);
