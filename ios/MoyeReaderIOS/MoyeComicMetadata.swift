import Foundation

// The site's Tags field also contains arbitrary reader jokes and comments.
// Exact matches against this vocabulary are deliberate: length limits or substring
// matches would still turn short comments (or "没有 NTR") into a comic's genre.
enum MoyeComicMetadata {
    private static let termGroups: [[String]] = [
        ["韩漫", "韓漫"], ["日漫"], ["青年漫"], ["同人"], ["单本", "單本"],
        ["短篇"], ["全彩"], ["黑白"], ["CG", "CG图集", "CG圖集"], ["3D"],
        ["Cosplay", "角色扮演"], ["AI绘图", "AI繪圖"],
        ["连载中", "連載中", "连载", "連載"], ["完结", "完結", "已完结", "已完結"],
        ["无修正", "無修正"], ["汉化", "漢化"], ["机翻", "機翻"],
        ["中文"], ["日文"], ["英文"], ["韩文", "韓文"],
        ["剧情", "劇情", "剧情向", "劇情向"], ["恋爱", "戀愛", "爱情", "愛情"],
        ["纯爱", "純愛"], ["恋爱喜剧", "戀愛喜劇"], ["浪漫"],
        ["喜剧", "喜劇", "搞笑"], ["日常"], ["都市"], ["校园", "校園"],
        ["奇幻"], ["现代奇幻", "現代奇幻"], ["异世界", "異世界"], ["重生"],
        ["科幻"], ["冒险", "冒險"], ["动作", "動作"], ["运动", "運動"],
        ["悬疑", "懸疑"], ["恐怖"], ["犯罪"], ["历史", "歷史"],
        ["时代剧", "時代劇"], ["单元剧", "單元劇"],
        ["后宫", "後宮", "后宮"], ["逆后宫", "逆後宮"], ["百合"], ["Yaoi", "BL"],
        ["女性向"], ["NTR"], ["NTL"], ["SM"], ["非H"],
        ["御姐"], ["熟女"], ["人妻"], ["教师", "教師", "老师", "老師"],
        ["女仆", "女僕"], ["护士", "護士"], ["办公女郎", "辦公女郎", "OL"],
        ["精灵", "精靈"], ["兽耳", "獸耳", "兽耳娘", "獸耳娘"], ["魅魔"],
        ["吸血鬼"], ["幽灵", "幽靈"], ["亚人", "亞人"], ["怪物女孩"],
        ["女装", "女裝"], ["性转", "性轉"], ["兔女郎"], ["巨乳"], ["贫乳", "貧乳"],
        ["超乳"], ["大乳晕", "大乳暈"], ["双马尾", "雙馬尾"], ["白毛"],
        ["校服"], ["制服", "其他制服"], ["泳装", "泳裝"], ["比基尼"],
        ["眼镜", "眼鏡"], ["丝袜", "絲襪"], ["裤袜", "褲襪", "连裤袜", "連褲襪"],
        ["女性支配"], ["催眠"], ["调教", "調教"], ["束缚", "束縛"],
        ["药物", "藥物"], ["触手", "觸手"], ["露出"], ["野外露出"],
        ["自慰"], ["手淫"], ["口交"], ["乳交"], ["足交"], ["肛交"], ["群交"],
        ["中出"], ["素股"], ["性玩具"], ["著衣乳交"], ["阿黑颜", "阿黑顏"],
        ["痴女", "癡女"], ["出轨", "出軌"], ["堕落", "墮落"], ["凌辱"],
        ["年龄差", "年齡差", "年龄差距", "年齡差距"], ["超能力"],
        ["重口"], ["猎奇", "獵奇"], ["血腥暴力"]
    ]

    private static func key(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static let canonicalTerms: [String: String] = {
        var terms: [String: String] = [:]
        for group in termGroups { for alias in group { terms[key(alias)] = group[0] } }
        return terms
    }()

    static func displayTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { raw in
            guard let term = canonicalTerms[key(raw)], seen.insert(term).inserted else { return nil }
            return term
        }
    }

    static func summary(record: [String: Any]) -> String {
        var parts: [String] = []
        if let raw = record["likesText"] as? String,
           let range = raw.range(of: #"(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?\s*[kKmM万萬亿億]?"#, options: .regularExpression) {
            parts.append("点赞 " + raw[range].trimmingCharacters(in: .whitespaces))
        }
        if let date = record["published"] as? String,
           date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            parts.append("上架 " + date)
        }
        // Cap the card's verified terms; the full title and author remain separate.
        parts.append(contentsOf: displayTags(record["tags"] as? [String] ?? []).prefix(8))
        return parts.joined(separator: " · ")
    }
}
