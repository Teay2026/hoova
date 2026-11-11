import Foundation
import NaturalLanguage

/// La langue des explications : celle du texte lu, ou une langue choisie par l'utilisateur.
public enum ExplanationLanguage {
    /// Le réglage, dans les préférences de Hoova : `text` pour la langue du texte, sinon le code d'une langue.
    /// `HOOVA_LANGUAGE` le remplace, pour le banc d'essai.
    public static let key = "explanationLanguage"
    /// Le réglage « la langue du texte », celui par défaut.
    public static let text = "text"
    /// Les langues proposées en plus de la langue du texte : celles du banc d'essai.
    public static let choices = ["fr", "en", "es", "de", "it", "pt", "zh-Hans", "ja"]

    public static var setting: String {
        ProcessInfo.processInfo.environment["HOOVA_LANGUAGE"] ?? UserDefaults.standard.string(forKey: key) ?? text
    }

    /// La langue dans laquelle expliquer ce terme : celle du réglage, sinon celle du contexte. Quand le contexte est trop
    /// court pour la reconnaître (« Agenda », « Modifications »), celle du Mac.
    public static func code(for capture: Capture) -> String {
        let setting = setting
        guard setting == text else { return setting }
        return context(of: capture) ?? reader
    }

    /// La langue du contexte, jamais celle du terme : un mot ou une citation en anglais, dans une page en français,
    /// s'explique en français (demande de l'utilisateur, 9 novembre 2026). D'abord le texte autour du passage, sinon le
    /// passage sans le terme, sinon avec le titre.
    static func context(of capture: Capture) -> String? {
        let around = [capture.before.map { String($0.suffix(1_500)) }, capture.after.map { String($0.prefix(500)) }]
            .compactMap { $0 }.joined(separator: "\n")
        if let language = recognize(around) { return language }
        let passage = capture.context.replacingOccurrences(of: capture.term, with: " ")
        if let language = recognize(passage) { return language }
        // Le terme n'est qu'une petite part du passage : le passage entier dit encore la langue du contexte. Sans lui, un
        // passage court qui mêle les écritures se reconnaît mal (chinois simplifié et traditionnel, et de l'anglais).
        if capture.term.count * 2 < capture.context.count, let language = recognize(capture.context) { return language }
        return capture.title.flatMap { recognize(passage + "\n" + $0) }
    }

    /// La langue du passage lu, si macOS la reconnaît. Le titre ne sert que si le passage seul est trop court (une
    /// légende, un bouton) : un titre dans une autre écriture brouillerait un passage qu'on reconnaît très bien.
    static func passage(of capture: Capture) -> String? {
        if let language = recognize(capture.context) { return language }
        return capture.title.flatMap { recognize(capture.context + "\n" + $0) }
    }

    /// La langue d'un texte, si macOS la reconnaît avec assurance : une phrase suffit, un mot seul rarement. Les
    /// variantes d'une langue comptent ensemble : un texte qui mêle chinois simplifié et traditionnel est du chinois.
    public static func recognize(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 4)
        guard let best = hypotheses.max(by: { $0.value < $1.value }) else { return nil }
        let base = best.key.rawValue.prefix(2)
        let confidence = hypotheses.filter { $0.key.rawValue.prefix(2) == base }.values.reduce(0, +)
        return confidence >= 0.8 ? best.key.rawValue : nil
    }

    /// Le nom d'une langue dans cette langue, pour le réglage : « Français », « English », « 日本語 ».
    public static func nativeName(of code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code)?.capitalized(with: locale) ?? code
    }

    /// Le nom d'une langue en anglais, pour le prompt : « French », « Simplified Chinese ».
    static func name(of code: String) -> String {
        switch code {
        case "zh-Hans": "Simplified Chinese"
        case "zh-Hant": "Traditional Chinese"
        default: Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
        }
    }

    /// La première langue du Mac.
    private static var reader: String {
        Locale.preferredLanguages.first.map { Locale.Language(identifier: $0).minimalIdentifier } ?? "en"
    }
}
