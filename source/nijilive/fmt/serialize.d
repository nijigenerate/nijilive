module nijilive.fmt.serialize;
import nijilive.core;
import std.json;
public import fghj;
public import nijilive.math.serialization;

import std.array : appender, Appender;
import std.functional : forward;
import std.range.primitives : put;

/**
    Interface for classes that can be serialized to JSON with custom code
*/
interface ISerializable {
    /**
        Custom serializer function
    */
    void serialize(S)(ref S serializer);
}

/**
    Interface for classes that can be deserialized to JSON with custom code
*/
interface IDeserializable(T) {

    /**
        Custom deserializer function
    */
    static T deserialize(Fghj data);
}

/**
    Tells serializer to ignore
*/
alias Ignore = serdeIgnore;

/**
    Tells serializer that a key is optional
*/
alias Optional = serdeOptional;

/**
    Sets the name of a key.

    First key is JSON key name, second is human-readable name
*/
alias Name = serdeKeys;

/**
    Loads JSON data from memory
*/
T inLoadJsonData(T)(string file) {
    return inLoadJsonDataFromMemory(readText(file));
}


/**
    Loads JSON data from memory
*/
T inLoadJsonDataFromMemory(T)(string data) {
    inLastLoadDiagnostics = InLoadDiagnostics.init;
    return deserialize!T(parseJson(cast(string)data));
}

/**
    Serialize item with compact nijilive JSON serializer
*/
string inToJson(T)(T item) {
    auto app = appender!(char[]);
    auto serializer = inCreateSerializer(app);
    serializer.serializeValue(item);
    serializer.flush();
    return cast(string)app.data;
}

/**
    Serialize item with pretty nijilive JSON serializer
*/
string inToJsonPretty(T)(T item) {
    auto app = appender!(char[]);
    auto serializer = inCreatePrettySerializer(app);
    serializer.serializeValue(item);
    serializer.flush();
    return cast(string)app.data;
}

/** Avoid the upstream numeric serializer's extra quotes around nonfinite values. */
struct InochiSerializer {
    private alias Sink = void delegate(const(char)[]) pure nothrow @safe;
    JsonSerializer!("", Sink) backend;
    alias backend this;

    this(Sink sink) {
        backend = typeof(backend)(sink);
    }

    void serializeValue(V)(auto ref V value) {
        import std.traits : isFloatingPoint;
        static if (isFloatingPoint!V) {
            backend.putNumberValue(value);
        } else {
            fghj.serializeValue(this, value);
        }
    }
}

/** Bounded diagnostics for recovery of damaged deformation components. */
struct InLoadDiagnostics {
    size_t recoveredComponents;
    size_t repairedWeldingMappings;
    string[] warnings;
}

InLoadDiagnostics inLastLoadDiagnostics;

void inRecordWeldingRecovery(string context, size_t count) {
    inLastLoadDiagnostics.repairedWeldingMappings += count;
    if (inLastLoadDiagnostics.warnings.length < 32) {
        import std.format : format;
        inLastLoadDiagnostics.warnings ~= format("%s: removed %s inconsistent Welding mappings", context, count);
    }
}

void inRecordLoadRecovery(string context, size_t count) {
    inLastLoadDiagnostics.recoveredComponents += count;
    if (inLastLoadDiagnostics.warnings.length < 32) {
        import std.format : format;
        inLastLoadDiagnostics.warnings ~= format("%s: reconstructing %s nonfinite deformation components from finite mesh samples",
            context, count);
    }
}

/** Read legacy extra-quoted nonfinite tokens only at numeric fields. */
SerdeException inDeserializeNumber(T)(Fghj data, ref T value) {
    import std.traits : isFloatingPoint;
    static if (isFloatingPoint!T) {
        if (data.kind == Fghj.Kind.string) {
            string token;
            auto error = data.deserializeValue(token);
            if (error !is null) return error;
            if (token.length >= 2 && token[0] == '"' && token[$ - 1] == '"') {
                import std.string : toLower;
                auto inner = toLower(token[1 .. $ - 1]);
                switch (inner) {
                    case "nan", "+nan", "-nan": value = T.nan; return null;
                    case "inf", "+inf": value = T.infinity; return null;
                    case "-inf": value = -T.infinity; return null;
                    default: break;
                }
            }
        }
    }
    return data.deserializeValue(value);
}

/**
    Creates a pretty-serializer
*/
InochiSerializer inCreateSerializer(Appender!(char[]) app) {
    return InochiSerializer((const(char)[] chars) => put(app, chars));
}


string getString(Fghj data) {
    auto app = appender!(char[]);
    data.toString((const(char)[] chars) => put(app, chars));
    return cast(string)app.data;
}
