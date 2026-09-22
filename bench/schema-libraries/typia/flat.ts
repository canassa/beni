import typia, { type IValidation, type tags } from "typia";

type SafeInt = number
    & tags.Type<"int64">
    & tags.Minimum<-9007199254740991>
    & tags.Maximum<9007199254740991>;

export interface FlatWire {
    // Prevent Typia's lossy strict-object key-count diagnostic shortcut.
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
    // Prevent Typia's lossy strict-object key-count diagnostic shortcut.
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

export const validateWire = (input: unknown): IValidation<FlatWire> =>
    typia.validateEquals<FlatWire>(input);
export const validateProgram = (input: unknown): IValidation<FlatProgram> =>
    typia.validateEquals<FlatProgram>(input);
export const stringifyWire = (input: FlatWire): string =>
    typia.json.stringify<FlatWire>(input);
