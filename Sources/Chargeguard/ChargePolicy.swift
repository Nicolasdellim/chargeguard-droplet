struct ChargeRange: Equatable {
    let lower: Int
    let upper: Int
    func engineLower(mode: String) -> Int { lower + (mode == "legacy" ? 1 : 0) }
    var valid: Bool { lower >= 11 && upper <= 99 && upper >= lower + 2 }
}

