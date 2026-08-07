using System.Text.Json;
using System.Text.Json.Serialization;

namespace MirageWallpaper.Models;

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum WEPropertyType
{
    Bool,
    Slider,
    Color,
    Combo,
    TextInput,
    Text,
    Group,
    File,
    Directory,
    SceneTexture,
    UserShortcut,
    Unknown
}

[JsonConverter(typeof(WEPropertyValueConverter))]
public readonly record struct WEPropertyValue
{
    public enum ValueType { Bool, Number, String }
    public ValueType Type { get; }
    public object RawValue { get; }

    public WEPropertyValue(bool value) { Type = ValueType.Bool; RawValue = value; }
    public WEPropertyValue(double value) { Type = ValueType.Number; RawValue = value; }
    public WEPropertyValue(string value) { Type = ValueType.String; RawValue = value ?? ""; }

    public bool BoolValue => Type switch
    {
        ValueType.Bool => (bool)RawValue,
        ValueType.Number => (double)RawValue != 0,
        ValueType.String => bool.TryParse((string)RawValue, out var b) && b,
        _ => false
    };

    public double NumberValue => Type switch
    {
        ValueType.Bool => (bool)RawValue ? 1 : 0,
        ValueType.Number => (double)RawValue,
        ValueType.String => double.TryParse((string)RawValue, out var d) ? d : 0,
        _ => 0
    };

    public string StringValue => Type switch
    {
        ValueType.Bool => (bool)RawValue ? "true" : "false",
        ValueType.Number => ((double)RawValue).ToString("G"),
        ValueType.String => (string)RawValue,
        _ => ""
    };

    public override string ToString() => StringValue;
}

public class WEPropertyValueConverter : JsonConverter<WEPropertyValue>
{
    public override WEPropertyValue Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        return reader.TokenType switch
        {
            JsonTokenType.True => new WEPropertyValue(true),
            JsonTokenType.False => new WEPropertyValue(false),
            JsonTokenType.Number => new WEPropertyValue(reader.GetDouble()),
            JsonTokenType.String => new WEPropertyValue(reader.GetString() ?? ""),
            _ => new WEPropertyValue("")
        };
    }

    public override void Write(Utf8JsonWriter writer, WEPropertyValue value, JsonSerializerOptions options)
    {
        switch (value.Type)
        {
            case WEPropertyValue.ValueType.Bool:
                writer.WriteBooleanValue(value.BoolValue);
                break;
            case WEPropertyValue.ValueType.Number:
                writer.WriteNumberValue(value.NumberValue);
                break;
            case WEPropertyValue.ValueType.String:
                writer.WriteStringValue(value.StringValue);
                break;
        }
    }
}

public record WEProjectPropertyOption
{
    public string Label { get; init; } = "";
    public WEPropertyValue Value { get; init; }
    public string? Condition { get; init; }
}

public record WEProjectProperty
{
    public string? Condition { get; init; }
    public int? Index { get; init; }
    public List<WEProjectPropertyOption>? Options { get; init; }
    public int? Order { get; init; }
    public double? Min { get; init; }
    public double? Max { get; init; }
    public double? Step { get; init; }
    public bool? Fraction { get; init; }
    public string? Mode { get; init; }
    public bool IsPresetOnly { get; init; }
    public string? Text { get; init; }
    public string Type { get; init; } = "unknown";
    public WEPropertyValue Value { get; init; }

    [JsonIgnore]
    public WEPropertyType PropertyType => Enum.TryParse<WEPropertyType>(Type, true, out var t) ? t : WEPropertyType.Unknown;
}

public record WEProjectProperties
{
    public Dictionary<string, WEProjectProperty> Items { get; init; } = new();
}

public record WEProjectGeneral
{
    public WEProjectProperties? Properties { get; init; }
    public string? Supportsaudioprocessing { get; init; }
}

public record WEProjectPreset
{
    public Dictionary<string, WEPropertyValue> Keys { get; init; } = new();
}

public record WEProject
{
    public string? Title { get; init; }
    public string? Type { get; init; }
    public string? File { get; init; }
    public string? Description { get; init; }
    public WEProjectGeneral? General { get; init; }
    public WEProjectPreset? Preset { get; init; }
    public string? Preview { get; init; }
    public string? Workshopid { get; init; }
    public string? Contentrating { get; init; }
    public List<string>? Tags { get; init; }
}
