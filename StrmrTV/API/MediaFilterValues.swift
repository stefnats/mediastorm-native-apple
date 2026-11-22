import Foundation

/// The same registered language identifiers as the existing Go/Android contract.
/// ISO 639-2 aliases below are static identifiers, not a new language service.
enum MediaFilterValues {
    private static let registered: Set<String> = {
        guard let url = Bundle.main.url(forResource: "MediaFilterLanguageCodes", withExtension: "json"),
              let raw = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([String].self, from: raw) else { return [] }
        return Set(values)
    }()
    private static let aliases: [String: String] = [
        "aa": "aar", "ab": "abk", "ae": "ave", "af": "afr", "ak": "aka", "alb": "sqi",
        "am": "amh", "an": "arg", "ar": "ara", "arm": "hye", "as": "asm", "av": "ava",
        "ay": "aym", "az": "aze", "ba": "bak", "baq": "eus", "be": "bel", "bg": "bul",
        "bi": "bis", "bm": "bam", "bn": "ben", "bo": "bod", "br": "bre", "bs": "bos",
        "bur": "mya", "ca": "cat", "ce": "che", "ch": "cha", "chi": "zho", "co": "cos",
        "cr": "cre", "cs": "ces", "cu": "chu", "cv": "chv", "cy": "cym", "cze": "ces",
        "da": "dan", "de": "deu", "dut": "nld", "dv": "div", "dz": "dzo", "ee": "ewe",
        "el": "ell", "en": "eng", "eo": "epo", "es": "spa", "et": "est", "eu": "eus",
        "fa": "fas", "ff": "ful", "fi": "fin", "fj": "fij", "fo": "fao", "fr": "fra",
        "fre": "fra", "fy": "fry", "ga": "gle", "gd": "gla", "geo": "kat", "ger": "deu",
        "gl": "glg", "gn": "grn", "gre": "ell", "gu": "guj", "gv": "glv", "ha": "hau",
        "he": "heb", "hi": "hin", "ho": "hmo", "hr": "hrv", "ht": "hat", "hu": "hun",
        "hy": "hye", "hz": "her", "ia": "ina", "ice": "isl", "id": "ind", "ie": "ile",
        "ig": "ibo", "ii": "iii", "ik": "ipk", "in": "ind", "io": "ido", "is": "isl",
        "it": "ita", "iu": "iku", "iw": "heb", "ja": "jpn", "ji": "yid", "jv": "jav",
        "ka": "kat", "kg": "kon", "ki": "kik", "kj": "kua", "kk": "kaz", "kl": "kal",
        "km": "khm", "kn": "kan", "ko": "kor", "kr": "kau", "ks": "kas", "ku": "kur",
        "kv": "kom", "kw": "cor", "ky": "kir", "la": "lat", "lb": "ltz", "lg": "lug",
        "li": "lim", "ln": "lin", "lo": "lao", "lt": "lit", "lu": "lub", "lv": "lav",
        "mac": "mkd", "mao": "mri", "may": "msa", "mg": "mlg", "mh": "mah", "mi": "mri",
        "mk": "mkd", "ml": "mal", "mn": "mon", "mr": "mar", "ms": "msa", "mt": "mlt",
        "my": "mya", "na": "nau", "nb": "nob", "nd": "nde", "ne": "nep", "ng": "ndo",
        "nl": "nld", "nn": "nno", "no": "nor", "nr": "nbl", "nv": "nav", "ny": "nya",
        "oc": "oci", "oj": "oji", "om": "orm", "or": "ori", "os": "oss", "pa": "pan",
        "per": "fas", "pi": "pli", "pl": "pol", "ps": "pus", "pt": "por", "qu": "que",
        "rm": "roh", "rn": "run", "ro": "ron", "ru": "rus", "rum": "ron", "rw": "kin",
        "sa": "san", "sc": "srd", "sd": "snd", "se": "sme", "sg": "sag", "si": "sin",
        "sk": "slk", "sl": "slv", "slo": "slk", "sm": "smo", "sn": "sna", "so": "som",
        "sq": "sqi", "sr": "srp", "ss": "ssw", "st": "sot", "su": "sun", "sv": "swe",
        "sw": "swa", "ta": "tam", "te": "tel", "tg": "tgk", "th": "tha", "ti": "tir",
        "tib": "bod", "tk": "tuk", "tn": "tsn", "to": "ton", "tr": "tur", "ts": "tso",
        "tt": "tat", "tw": "twi", "ty": "tah", "ug": "uig", "uk": "ukr", "ur": "urd",
        "uz": "uzb", "ve": "ven", "vi": "vie", "vo": "vol", "wa": "wln", "wel": "cym",
        "wo": "wol", "xh": "xho", "yi": "yid", "yo": "yor", "za": "zha", "zh": "zho",
        "zu": "zul",
    ]
    static func language(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.range(of: #"^[a-z]{2,3}$"#, options: .regularExpression) != nil,
              !["und", "mul", "zxx"].contains(value) else { return nil }
        let canonical = aliases[value] ?? value
        return registered.contains(canonical) ? canonical : nil
    }
    static var languages: [String] {
        Array(Set(Locale.isoLanguageCodes.compactMap(language))).sorted { label($0).localizedCaseInsensitiveCompare(label($1)) == .orderedAscending }
    }
    static func label(_ code: String) -> String { Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased() }
    static let videoCodecs = ["h264", "hevc", "av1", "vp9", "mpeg2video"]
    static let audioCodecs = ["aac", "ac3", "eac3", "dts", "truehd", "flac", "opus", "mp3", "pcm_s16le"]
    static let ranges = ["sdr", "hdr10", "hlg", "dolby_vision"]
    static let heights = [480, 576, 720, 1080, 1440, 2160, 4320]
    static func codec(_ value: String?) -> Bool { value == nil || value?.range(of: #"^[a-z0-9_]{1,32}$"#, options: .regularExpression) != nil }
}
