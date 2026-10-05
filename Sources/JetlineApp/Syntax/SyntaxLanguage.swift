import Foundation

/// Lexical rules for one language, as much as the diff view's highlighter
/// needs: comments, strings, keywords and a few literal classes. Deliberately
/// not a grammar — it colors tokens, it doesn't parse.
struct SyntaxLanguage: Sendable {
    var name: String
    var lineComments: [String] = []
    var blockComment: (open: String, close: String)?
    /// Single-line string delimiters. A string left open at the end of the
    /// line ends there.
    var stringDelimiters: Set<Character> = ["\"", "'"]
    /// Delimiters of strings that may span lines (`"""`, `` ` ``).
    var multilineStrings: [String] = []
    var keywords: Set<String> = []
    /// `true`, `nil`, `None`, … — colored like keywords.
    var literals: Set<String> = []
    /// Capitalized identifiers read as type names.
    var capitalizedAreTypes = false
    /// `@name` is an attribute / decorator / annotation / at-rule.
    var atAttributes = false
    /// `#name` is a directive (`#include`, `#if`, `#available`).
    var hashDirectives = false
    /// `$name` is a variable (shell, PHP-ish).
    var dollarVariables = false
    var caseInsensitiveKeywords = false

    /// The language for `path`, by file name or extension. Nil for anything
    /// unrecognized, which renders as plain text.
    static func forPath(_ path: String) -> SyntaxLanguage? {
        let name = (path as NSString).lastPathComponent
        switch name {
        case "Makefile", "makefile", "GNUmakefile": return .shell
        case "Dockerfile": return .dockerfile
        case "Package.resolved", ".prettierrc", ".eslintrc": return .json
        default: break
        }
        if name.hasPrefix(".") && !name.dropFirst().contains(".") {
            // Dotfiles like .zshrc / .bashrc / .env
            return name.hasSuffix("rc") || name == ".env" ? .shell : nil
        }
        return forExtension((name as NSString).pathExtension)
    }

    static func forExtension(_ ext: String) -> SyntaxLanguage? {
        switch ext.lowercased() {
        case "swift": return .swift
        case "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs": return .javascript
        case "svelte", "vue": return .javascript
        case "py", "pyi": return .python
        case "go": return .go
        case "rs": return .rust
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm": return .c
        case "cs": return .csharp
        case "rb", "rake", "gemspec": return .ruby
        case "sh", "bash", "zsh", "fish", "env": return .shell
        case "json", "jsonc", "json5": return .json
        case "yaml", "yml": return .yaml
        case "toml": return .toml
        case "css", "scss", "sass", "less": return .css
        case "html", "htm", "xml", "plist", "svg", "xib", "storyboard": return .markup
        case "sql": return .sql
        case "php": return .php
        default: return nil
        }
    }

    /// The language for a markdown fence's info string (`swift`, `ts`,
    /// `shell`, …): a name or an extension. Nil for anything unrecognized.
    static func forFence(_ name: String) -> SyntaxLanguage? {
        switch name.lowercased() {
        case "typescript", "javascript", "node": return .javascript
        case "python", "python3", "py3": return .python
        case "golang": return .go
        case "rust": return .rust
        case "kotlin": return .kotlin
        case "objc", "objective-c", "objectivec", "c++", "cpp": return .c
        case "c#", "csharp": return .csharp
        case "ruby": return .ruby
        case "shell", "console", "shellscript", "sh-session", "make", "makefile": return .shell
        case "dockerfile", "docker": return .dockerfile
        case "postgresql", "postgres", "mysql", "sqlite", "psql": return .sql
        case let other: return forExtension(other)
        }
    }
}

extension SyntaxLanguage {
    static let swift = SyntaxLanguage(
        name: "Swift",
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\""],
        multilineStrings: ["\"\"\""],
        keywords: [
            "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch",
            "class", "continue", "convenience", "default", "defer", "deinit", "didSet", "do",
            "dynamic", "else", "enum", "extension", "fallthrough", "fileprivate", "final", "for",
            "func", "get", "guard", "if", "import", "in", "indirect", "init", "inout", "internal",
            "is", "lazy", "let", "macro", "mutating", "nonisolated", "nonmutating", "open",
            "operator", "override", "package", "private", "protocol", "public", "repeat",
            "required", "rethrows", "return", "self", "Self", "set", "some", "static", "struct",
            "subscript", "super", "switch", "throw", "throws", "try", "typealias", "unowned",
            "var", "weak", "where", "while", "willSet", "consuming", "borrowing", "sending",
        ],
        literals: ["true", "false", "nil"],
        capitalizedAreTypes: true,
        atAttributes: true,
        hashDirectives: true
    )

    static let javascript = SyntaxLanguage(
        name: "JavaScript",
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        multilineStrings: ["`"],
        keywords: [
            "abstract", "as", "async", "await", "break", "case", "catch", "class", "const",
            "constructor", "continue", "debugger", "declare", "default", "delete", "do", "else",
            "enum", "export", "extends", "finally", "for", "from", "function", "get", "if",
            "implements", "import", "in", "infer", "instanceof", "interface", "is", "keyof", "let",
            "namespace", "new", "of", "private", "protected", "public", "readonly", "return",
            "satisfies", "set", "static", "super", "switch", "this", "throw", "try", "type",
            "typeof", "var", "void", "while", "with", "yield",
            "string", "number", "boolean", "unknown", "never", "any", "object", "symbol", "bigint",
        ],
        literals: ["true", "false", "null", "undefined", "NaN", "Infinity"],
        capitalizedAreTypes: true,
        atAttributes: true
    )

    static let python = SyntaxLanguage(
        name: "Python",
        lineComments: ["#"],
        multilineStrings: ["\"\"\"", "'''"],
        keywords: [
            "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def",
            "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import",
            "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return",
            "self", "try", "while", "with", "yield",
        ],
        literals: ["True", "False", "None"],
        capitalizedAreTypes: true,
        atAttributes: true
    )

    static let go = SyntaxLanguage(
        name: "Go",
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        multilineStrings: ["`"],
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else",
            "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
            "package", "range", "return", "select", "struct", "switch", "type", "var",
            "bool", "byte", "error", "float32", "float64", "int", "int8", "int16", "int32",
            "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
            "any",
        ],
        literals: ["true", "false", "nil", "iota"],
        capitalizedAreTypes: false
    )

    static let rust = SyntaxLanguage(
        name: "Rust",
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        // `'` is also a lifetime sigil (`'a`), so char literals go uncolored
        // rather than turning the rest of a line into a string.
        stringDelimiters: ["\""],
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
            "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move",
            "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait",
            "type", "unsafe", "use", "where", "while",
            "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "str",
            "u8", "u16", "u32", "u64", "u128", "usize",
        ],
        literals: ["true", "false", "None", "Some", "Ok", "Err"],
        capitalizedAreTypes: true,
        hashDirectives: true
    )

    static let java = SyntaxLanguage(
        name: "Java",
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        multilineStrings: ["\"\"\""],
        keywords: [
            "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class",
            "const", "continue", "default", "do", "double", "else", "enum", "extends", "final",
            "finally", "float", "for", "if", "implements", "import", "instanceof", "int",
            "interface", "long", "native", "new", "package", "private", "protected", "public",
            "record", "return", "sealed", "short", "static", "super", "switch", "synchronized",
            "this", "throw", "throws", "transient", "try", "var", "void", "volatile", "while",
            "yield",
        ],
        literals: ["true", "false", "null"],
        capitalizedAreTypes: true,
        atAttributes: true
    )

    static let kotlin = SyntaxLanguage(
        name: "Kotlin",
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        multilineStrings: ["\"\"\""],
        keywords: [
            "abstract", "annotation", "as", "break", "by", "catch", "class", "companion", "const",
            "constructor", "continue", "data", "do", "else", "enum", "external", "final",
            "finally", "for", "fun", "get", "if", "import", "in", "infix", "init", "inline",
            "inner", "interface", "internal", "is", "lateinit", "object", "open", "operator",
            "out", "override", "package", "private", "protected", "public", "reified", "return",
            "sealed", "set", "super", "suspend", "this", "throw", "try", "typealias", "val",
            "var", "vararg", "when", "where", "while",
        ],
        literals: ["true", "false", "null"],
        capitalizedAreTypes: true,
        atAttributes: true
    )

    static let c = SyntaxLanguage(
        name: "C",
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        keywords: [
            "auto", "bool", "break", "case", "char", "class", "const", "constexpr", "continue",
            "default", "delete", "do", "double", "else", "enum", "explicit", "extern", "float",
            "for", "friend", "goto", "if", "inline", "int", "long", "namespace", "new",
            "noexcept", "operator", "private", "protected", "public", "register", "return",
            "short", "signed", "sizeof", "static", "struct", "switch", "template", "this",
            "throw", "try", "typedef", "typename", "union", "unsigned", "using", "virtual",
            "void", "volatile", "while",
            "self", "super", "id", "instancetype",
        ],
        literals: ["true", "false", "NULL", "nullptr", "nil", "YES", "NO"],
        capitalizedAreTypes: true,
        atAttributes: true,
        hashDirectives: true
    )

    static let csharp = SyntaxLanguage(
        name: "C#",
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        keywords: [
            "abstract", "as", "async", "await", "base", "bool", "break", "byte", "case", "catch",
            "char", "class", "const", "continue", "decimal", "default", "delegate", "do",
            "double", "else", "enum", "event", "explicit", "extern", "finally", "fixed", "float",
            "for", "foreach", "get", "if", "implicit", "in", "init", "int", "interface",
            "internal", "is", "lock", "long", "namespace", "new", "object", "operator", "out",
            "override", "params", "private", "protected", "public", "readonly", "record", "ref",
            "return", "sealed", "set", "short", "static", "string", "struct", "switch", "this",
            "throw", "try", "typeof", "uint", "ulong", "using", "var", "virtual", "void",
            "while", "yield",
        ],
        literals: ["true", "false", "null"],
        capitalizedAreTypes: true,
        hashDirectives: true
    )

    static let ruby = SyntaxLanguage(
        name: "Ruby",
        lineComments: ["#"],
        keywords: [
            "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else",
            "elsif", "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo",
            "rescue", "retry", "return", "self", "super", "then", "undef", "unless", "until",
            "when", "while", "yield", "require", "attr_reader", "attr_accessor", "private",
        ],
        literals: ["true", "false", "nil"],
        capitalizedAreTypes: true
    )

    static let shell = SyntaxLanguage(
        name: "Shell",
        lineComments: ["#"],
        keywords: [
            "case", "do", "done", "elif", "else", "esac", "exit", "export", "fi", "for",
            "function", "if", "in", "local", "readonly", "return", "set", "shift", "source",
            "then", "unset", "until", "while", "echo", "cd", "eval", "exec", "trap",
        ],
        literals: ["true", "false"],
        dollarVariables: true
    )

    static let dockerfile = SyntaxLanguage(
        name: "Dockerfile",
        lineComments: ["#"],
        keywords: [
            "FROM", "RUN", "CMD", "LABEL", "EXPOSE", "ENV", "ADD", "COPY", "ENTRYPOINT",
            "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL",
            "AS",
        ],
        dollarVariables: true
    )

    static let json = SyntaxLanguage(
        name: "JSON",
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\""],
        literals: ["true", "false", "null"]
    )

    static let yaml = SyntaxLanguage(
        name: "YAML",
        lineComments: ["#"],
        literals: ["true", "false", "null", "yes", "no", "on", "off", "~"]
    )

    static let toml = SyntaxLanguage(
        name: "TOML",
        lineComments: ["#"],
        multilineStrings: ["\"\"\"", "'''"],
        literals: ["true", "false"]
    )

    static let css = SyntaxLanguage(
        name: "CSS",
        lineComments: ["//"],
        blockComment: ("/*", "*/"),
        keywords: ["important", "inherit", "initial", "unset", "none", "auto"],
        atAttributes: true,
        dollarVariables: true
    )

    static let markup = SyntaxLanguage(
        name: "Markup",
        blockComment: ("<!--", "-->"),
        stringDelimiters: ["\""]
    )

    static let sql = SyntaxLanguage(
        name: "SQL",
        lineComments: ["--"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["'"],
        keywords: [
            "add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case", "check",
            "column", "commit", "constraint", "create", "cross", "database", "default", "delete",
            "desc", "distinct", "drop", "else", "end", "exists", "foreign", "from", "full",
            "group", "having", "if", "in", "index", "inner", "insert", "into", "is", "join",
            "key", "left", "like", "limit", "not", "offset", "on", "or", "order", "outer",
            "primary", "references", "returning", "right", "rollback", "select", "set", "table",
            "then", "transaction", "trigger", "union", "unique", "update", "using", "values",
            "view", "when", "where", "with",
            "integer", "int", "bigint", "text", "varchar", "boolean", "real", "blob", "timestamp",
        ],
        literals: ["true", "false", "null"],
        caseInsensitiveKeywords: true
    )

    static let php = SyntaxLanguage(
        name: "PHP",
        lineComments: ["//", "#"],
        blockComment: ("/*", "*/"),
        keywords: [
            "abstract", "array", "as", "break", "case", "catch", "class", "const", "continue",
            "default", "do", "echo", "else", "elseif", "enum", "extends", "final", "finally",
            "fn", "for", "foreach", "function", "if", "implements", "interface", "match", "new",
            "namespace", "private", "protected", "public", "readonly", "require", "return",
            "static", "switch", "throw", "trait", "try", "use", "while", "yield",
        ],
        literals: ["true", "false", "null"],
        capitalizedAreTypes: true,
        dollarVariables: true
    )
}
