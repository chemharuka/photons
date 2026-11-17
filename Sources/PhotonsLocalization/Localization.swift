import Foundation

public enum L10n {
    /// Freeze the interface language for the lifetime of a process. Language changes apply on
    /// restart, so menu commands, open tool windows and background jobs never switch halfway.
    public static let defaultLanguage = "en"
    public static let language = (ProcessInfo.processInfo.environment["PHOTONS_LANGUAGE"]
        ?? UserDefaults.standard.string(forKey: "photons.language")
        ?? defaultLanguage) == "zh-Hans" ? "zh-Hans" : "en"
    private static func load(_ name:String)->[String:String] {
        guard let url=Bundle.module.url(forResource:name,withExtension:"json"),
              let data=try? Data(contentsOf:url),let table=try? JSONDecoder().decode([String:String].self,from:data) else {return [:]}
        return table
    }
    private static let chinese=load("zh-Hans")
    private static let english=load("en")
    private static let placeholder = try! NSRegularExpression(pattern:"\\{([0-9]+)\\}")
    public static func tr(_ key:String,_ arguments:String...)->String {
        var text=(language == "en" ? english[key]:nil) ?? chinese[key] ?? key
        // Replace from the end so user text resembling a later placeholder cannot be substituted.
        // Regex single-pass replacement below also leaves literal braces in filenames untouched.
        guard !arguments.isEmpty else {return text}
        let regex=placeholder
        let matches=regex.matches(in:text,range:NSRange(text.startIndex...,in:text))
        for match in matches.reversed() {
            guard let r=Range(match.range(at:1),in:text),let i=Int(text[r]),arguments.indices.contains(i),let all=Range(match.range,in:text) else {continue}
            text.replaceSubrange(all,with:arguments[i])
        }
        return text
    }
}
