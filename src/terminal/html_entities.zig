//! Shared named character references for display decoding: every HTML 4 name
//! plus common single-code-point HTML5 names. The table is sorted at comptime
//! and searched by bisection; nothing allocates. Callers still apply their own
//! control/bidi/invisible filters to the decoded code point.
const std = @import("std");

pub const Match = struct { consumed: usize, codepoint: u21 };
const Entry = struct { name: []const u8, cp: u21, legacy: bool = false };
const Pair = struct { []const u8, u21 };

/// U+00A0..U+00FF in order. HTML also accepts these without a semicolon.
const latin1 = [_][]const u8{
    "nbsp",   "iexcl",  "cent",   "pound",  "curren", "yen",    "brvbar", "sect",   "uml",    "copy",   "ordf",   "laquo",
    "not",    "shy",    "reg",    "macr",   "deg",    "plusmn", "sup2",   "sup3",   "acute",  "micro",  "para",   "middot",
    "cedil",  "sup1",   "ordm",   "raquo",  "frac14", "frac12", "frac34", "iquest", "Agrave", "Aacute", "Acirc",  "Atilde",
    "Auml",   "Aring",  "AElig",  "Ccedil", "Egrave", "Eacute", "Ecirc",  "Euml",   "Igrave", "Iacute", "Icirc",  "Iuml",
    "ETH",    "Ntilde", "Ograve", "Oacute", "Ocirc",  "Otilde", "Ouml",   "times",  "Oslash", "Ugrave", "Uacute", "Ucirc",
    "Uuml",   "Yacute", "THORN",  "szlig",  "agrave", "aacute", "acirc",  "atilde", "auml",   "aring",  "aelig",  "ccedil",
    "egrave", "eacute", "ecirc",  "euml",   "igrave", "iacute", "icirc",  "iuml",   "eth",    "ntilde", "ograve", "oacute",
    "ocirc",  "otilde", "ouml",   "divide", "oslash", "ugrave", "uacute", "ucirc",  "uuml",   "yacute", "thorn",  "yuml",
};
const legacy_other = [_]Pair{ .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "quot", '"' }, .{ "AMP", '&' }, .{ "LT", '<' }, .{ "GT", '>' }, .{ "QUOT", '"' }, .{ "COPY", 0xa9 }, .{ "REG", 0xae } };
/// U+0391..U+03A9 and U+03B1..U+03C9; "" marks the unassigned U+03A2.
const greek_upper = [_][]const u8{ "Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta", "Iota", "Kappa", "Lambda", "Mu", "Nu", "Xi", "Omicron", "Pi", "Rho", "", "Sigma", "Tau", "Upsilon", "Phi", "Chi", "Psi", "Omega" };
const greek_lower = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda", "mu", "nu", "xi", "omicron", "pi", "rho", "sigmaf", "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega" };
const others = [_]Pair{
    // HTML 4 special characters.
    .{ "apos", '\'' },              .{ "OElig", 0x152 },                 .{ "oelig", 0x153 },                  .{ "Scaron", 0x160 },       .{ "scaron", 0x161 },          .{ "Yuml", 0x178 },
    .{ "circ", 0x2c6 },             .{ "tilde", 0x2dc },                 .{ "ensp", 0x2002 },                  .{ "emsp", 0x2003 },        .{ "thinsp", 0x2009 },         .{ "zwnj", 0x200c },
    .{ "zwj", 0x200d },             .{ "lrm", 0x200e },                  .{ "rlm", 0x200f },                   .{ "ndash", 0x2013 },       .{ "mdash", 0x2014 },          .{ "lsquo", 0x2018 },
    .{ "rsquo", 0x2019 },           .{ "sbquo", 0x201a },                .{ "ldquo", 0x201c },                 .{ "rdquo", 0x201d },       .{ "bdquo", 0x201e },          .{ "dagger", 0x2020 },
    .{ "Dagger", 0x2021 },          .{ "permil", 0x2030 },               .{ "lsaquo", 0x2039 },                .{ "rsaquo", 0x203a },      .{ "euro", 0x20ac },
    // HTML 4 symbols.
              .{ "fnof", 0x192 },
    .{ "thetasym", 0x3d1 },         .{ "upsih", 0x3d2 },                 .{ "piv", 0x3d6 },                    .{ "bull", 0x2022 },        .{ "hellip", 0x2026 },         .{ "prime", 0x2032 },
    .{ "Prime", 0x2033 },           .{ "oline", 0x203e },                .{ "frasl", 0x2044 },                 .{ "weierp", 0x2118 },      .{ "image", 0x2111 },          .{ "real", 0x211c },
    .{ "trade", 0x2122 },           .{ "alefsym", 0x2135 },              .{ "larr", 0x2190 },                  .{ "uarr", 0x2191 },        .{ "rarr", 0x2192 },           .{ "darr", 0x2193 },
    .{ "harr", 0x2194 },            .{ "crarr", 0x21b5 },                .{ "lArr", 0x21d0 },                  .{ "uArr", 0x21d1 },        .{ "rArr", 0x21d2 },           .{ "dArr", 0x21d3 },
    .{ "hArr", 0x21d4 },            .{ "forall", 0x2200 },               .{ "part", 0x2202 },                  .{ "exist", 0x2203 },       .{ "empty", 0x2205 },          .{ "nabla", 0x2207 },
    .{ "isin", 0x2208 },            .{ "notin", 0x2209 },                .{ "ni", 0x220b },                    .{ "prod", 0x220f },        .{ "sum", 0x2211 },            .{ "minus", 0x2212 },
    .{ "lowast", 0x2217 },          .{ "radic", 0x221a },                .{ "prop", 0x221d },                  .{ "infin", 0x221e },       .{ "ang", 0x2220 },            .{ "and", 0x2227 },
    .{ "or", 0x2228 },              .{ "cap", 0x2229 },                  .{ "cup", 0x222a },                   .{ "int", 0x222b },         .{ "there4", 0x2234 },         .{ "sim", 0x223c },
    .{ "cong", 0x2245 },            .{ "asymp", 0x2248 },                .{ "ne", 0x2260 },                    .{ "equiv", 0x2261 },       .{ "le", 0x2264 },             .{ "ge", 0x2265 },
    .{ "sub", 0x2282 },             .{ "sup", 0x2283 },                  .{ "nsub", 0x2284 },                  .{ "sube", 0x2286 },        .{ "supe", 0x2287 },           .{ "oplus", 0x2295 },
    .{ "otimes", 0x2297 },          .{ "perp", 0x22a5 },                 .{ "sdot", 0x22c5 },                  .{ "lceil", 0x2308 },       .{ "rceil", 0x2309 },          .{ "lfloor", 0x230a },
    .{ "rfloor", 0x230b },          .{ "lang", 0x27e8 },                 .{ "rang", 0x27e9 },                  .{ "loz", 0x25ca },         .{ "spades", 0x2660 },         .{ "clubs", 0x2663 },
    .{ "hearts", 0x2665 },          .{ "diams", 0x2666 },
    // Common HTML5 names: spaces and invisible format characters.
                   .{ "Tab", 9 },                        .{ "NewLine", 10 },         .{ "NonBreakingSpace", 0xa0 }, .{ "emsp13", 0x2004 },
    .{ "emsp14", 0x2005 },          .{ "numsp", 0x2007 },                .{ "puncsp", 0x2008 },                .{ "ThinSpace", 0x2009 },   .{ "hairsp", 0x200a },         .{ "VeryThinSpace", 0x200a },
    .{ "ZeroWidthSpace", 0x200b },  .{ "MediumSpace", 0x205f },          .{ "NoBreak", 0x2060 },
    // ASCII punctuation.
                  .{ "excl", '!' },           .{ "num", '#' },               .{ "dollar", '$' },
    .{ "percnt", '%' },             .{ "lpar", '(' },                    .{ "rpar", ')' },                     .{ "ast", '*' },            .{ "plus", '+' },              .{ "comma", ',' },
    .{ "period", '.' },             .{ "sol", '/' },                     .{ "colon", ':' },                    .{ "semi", ';' },           .{ "equals", '=' },            .{ "quest", '?' },
    .{ "commat", '@' },             .{ "lsqb", '[' },                    .{ "lbrack", '[' },                   .{ "bsol", '\\' },          .{ "rsqb", ']' },              .{ "rbrack", ']' },
    .{ "Hat", '^' },                .{ "lowbar", '_' },                  .{ "grave", '`' },                    .{ "lcub", '{' },           .{ "lbrace", '{' },            .{ "verbar", '|' },
    .{ "vert", '|' },               .{ "rcub", '}' },                    .{ "rbrace", '}' },
    // Typography.
                      .{ "TRADE", 0x2122 },       .{ "hyphen", 0x2010 },         .{ "dash", 0x2010 },
    .{ "horbar", 0x2015 },          .{ "lsquor", 0x201a },               .{ "rsquor", 0x2019 },                .{ "ldquor", 0x201e },      .{ "rdquor", 0x201d },         .{ "OpenCurlyQuote", 0x2018 },
    .{ "CloseCurlyQuote", 0x2019 }, .{ "OpenCurlyDoubleQuote", 0x201c }, .{ "CloseCurlyDoubleQuote", 0x201d }, .{ "ddagger", 0x2021 },     .{ "bullet", 0x2022 },         .{ "nldr", 0x2025 },
    .{ "mldr", 0x2026 },            .{ "pertenk", 0x2031 },              .{ "tprime", 0x2034 },                .{ "bprime", 0x2035 },      .{ "backprime", 0x2035 },      .{ "caret", 0x2041 },
    .{ "hybull", 0x2043 },          .{ "qprime", 0x2057 },               .{ "centerdot", 0xb7 },               .{ "half", 0xbd },          .{ "die", 0xa8 },              .{ "Dot", 0xa8 },
    .{ "pm", 0xb1 },                .{ "div", 0xf7 },                    .{ "angst", 0xc5 },                   .{ "caron", 0x2c7 },        .{ "breve", 0x2d8 },           .{ "dot", 0x2d9 },
    .{ "ring", 0x2da },             .{ "ogon", 0x2db },                  .{ "dblac", 0x2dd },                  .{ "frac13", 0x2153 },      .{ "frac23", 0x2154 },         .{ "frac15", 0x2155 },
    .{ "frac18", 0x215b },          .{ "frac38", 0x215c },               .{ "frac58", 0x215d },                .{ "frac78", 0x215e },      .{ "incare", 0x2105 },         .{ "hbar", 0x210f },
    .{ "planck", 0x210f },          .{ "ell", 0x2113 },                  .{ "numero", 0x2116 },                .{ "copysr", 0x2117 },      .{ "ohm", 0x3a9 },             .{ "mho", 0x2127 },
    // Latin Extended-A letters used by European languages.
    .{ "Amacr", 0x100 },            .{ "amacr", 0x101 },                 .{ "Abreve", 0x102 },                 .{ "abreve", 0x103 },       .{ "Aogon", 0x104 },           .{ "aogon", 0x105 },
    .{ "Cacute", 0x106 },           .{ "cacute", 0x107 },                .{ "Ccaron", 0x10c },                 .{ "ccaron", 0x10d },       .{ "Dcaron", 0x10e },          .{ "dcaron", 0x10f },
    .{ "Dstrok", 0x110 },           .{ "dstrok", 0x111 },                .{ "Emacr", 0x112 },                  .{ "emacr", 0x113 },        .{ "Eogon", 0x118 },           .{ "eogon", 0x119 },
    .{ "Ecaron", 0x11a },           .{ "ecaron", 0x11b },                .{ "Gbreve", 0x11e },                 .{ "gbreve", 0x11f },       .{ "Imacr", 0x12a },           .{ "imacr", 0x12b },
    .{ "Idot", 0x130 },             .{ "inodot", 0x131 },                .{ "imath", 0x131 },                  .{ "Lstrok", 0x141 },       .{ "lstrok", 0x142 },          .{ "Nacute", 0x143 },
    .{ "nacute", 0x144 },           .{ "Ncaron", 0x147 },                .{ "ncaron", 0x148 },                 .{ "Omacr", 0x14c },        .{ "omacr", 0x14d },           .{ "Odblac", 0x150 },
    .{ "odblac", 0x151 },           .{ "Rcaron", 0x158 },                .{ "rcaron", 0x159 },                 .{ "Sacute", 0x15a },       .{ "sacute", 0x15b },          .{ "Scedil", 0x15e },
    .{ "scedil", 0x15f },           .{ "Tcedil", 0x162 },                .{ "tcedil", 0x163 },                 .{ "Tcaron", 0x164 },       .{ "tcaron", 0x165 },          .{ "Umacr", 0x16a },
    .{ "umacr", 0x16b },            .{ "Uring", 0x16e },                 .{ "uring", 0x16f },                  .{ "Udblac", 0x170 },       .{ "udblac", 0x171 },          .{ "Zacute", 0x179 },
    .{ "zacute", 0x17a },           .{ "Zdot", 0x17b },                  .{ "zdot", 0x17c },                   .{ "Zcaron", 0x17d },       .{ "zcaron", 0x17e },
    // Greek variants.
             .{ "epsi", 0x3b5 },
    .{ "epsiv", 0x3f5 },            .{ "varepsilon", 0x3f5 },            .{ "thetav", 0x3d1 },                 .{ "vartheta", 0x3d1 },     .{ "phiv", 0x3d5 },            .{ "varphi", 0x3d5 },
    .{ "straightphi", 0x3d5 },      .{ "rhov", 0x3f1 },                  .{ "varrho", 0x3f1 },                 .{ "sigmav", 0x3c2 },       .{ "varsigma", 0x3c2 },        .{ "kappav", 0x3f0 },
    // Arrows.
    .{ "leftarrow", 0x2190 },       .{ "uparrow", 0x2191 },              .{ "rightarrow", 0x2192 },            .{ "downarrow", 0x2193 },   .{ "leftrightarrow", 0x2194 }, .{ "varr", 0x2195 },
    .{ "LeftArrow", 0x2190 },       .{ "UpArrow", 0x2191 },              .{ "RightArrow", 0x2192 },            .{ "DownArrow", 0x2193 },   .{ "nwarr", 0x2196 },          .{ "nearr", 0x2197 },
    .{ "searr", 0x2198 },           .{ "swarr", 0x2199 },                .{ "larrhk", 0x21a9 },                .{ "rarrhk", 0x21aa },      .{ "map", 0x21a6 },            .{ "mapsto", 0x21a6 },
    .{ "Leftarrow", 0x21d0 },       .{ "Rightarrow", 0x21d2 },           .{ "Leftrightarrow", 0x21d4 },        .{ "iff", 0x21d4 },         .{ "Implies", 0x21d2 },        .{ "vArr", 0x21d5 },
    // Mathematics.
    .{ "emptyset", 0x2205 },        .{ "varnothing", 0x2205 },           .{ "in", 0x2208 },                    .{ "mp", 0x2213 },          .{ "setminus", 0x2216 },       .{ "compfn", 0x2218 },
    .{ "Sqrt", 0x221a },            .{ "angle", 0x2220 },                .{ "mid", 0x2223 },                   .{ "par", 0x2225 },         .{ "parallel", 0x2225 },       .{ "wedge", 0x2227 },
    .{ "vee", 0x2228 },             .{ "therefore", 0x2234 },            .{ "because", 0x2235 },               .{ "becaus", 0x2235 },      .{ "Colon", 0x2237 },          .{ "simeq", 0x2243 },
    .{ "approx", 0x2248 },          .{ "ap", 0x2248 },                   .{ "leq", 0x2264 },                   .{ "geq", 0x2265 },         .{ "subset", 0x2282 },         .{ "supset", 0x2283 },
    .{ "subseteq", 0x2286 },        .{ "supseteq", 0x2287 },             .{ "top", 0x22a4 },                   .{ "bot", 0x22a5 },         .{ "bottom", 0x22a5 },         .{ "vellip", 0x22ee },
    .{ "ctdot", 0x22ef },           .{ "dtdot", 0x22f1 },                .{ "langle", 0x27e8 },                .{ "rangle", 0x27e9 },
    // Shapes and dingbats.
         .{ "boxh", 0x2500 },           .{ "boxv", 0x2502 },
    .{ "uhblk", 0x2580 },           .{ "lhblk", 0x2584 },                .{ "block", 0x2588 },                 .{ "blk14", 0x2591 },       .{ "blk12", 0x2592 },          .{ "blk34", 0x2593 },
    .{ "squ", 0x25a1 },             .{ "square", 0x25a1 },               .{ "squf", 0x25aa },                  .{ "blacksquare", 0x25aa }, .{ "utrif", 0x25b4 },          .{ "utri", 0x25b5 },
    .{ "rtrif", 0x25b8 },           .{ "rtri", 0x25b9 },                 .{ "dtrif", 0x25be },                 .{ "dtri", 0x25bf },        .{ "ltrif", 0x25c2 },          .{ "ltri", 0x25c3 },
    .{ "cir", 0x25cb },             .{ "starf", 0x2605 },                .{ "bigstar", 0x2605 },               .{ "star", 0x2606 },        .{ "phone", 0x260e },          .{ "female", 0x2640 },
    .{ "male", 0x2642 },            .{ "spadesuit", 0x2660 },            .{ "clubsuit", 0x2663 },              .{ "heartsuit", 0x2665 },   .{ "diamondsuit", 0x2666 },    .{ "sung", 0x266a },
    .{ "flat", 0x266d },            .{ "natural", 0x266e },              .{ "sharp", 0x266f },                 .{ "check", 0x2713 },       .{ "checkmark", 0x2713 },      .{ "cross", 0x2717 },
    .{ "malt", 0x2720 },            .{ "sext", 0x2736 },
};

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}
const table = blk: {
    @setEvalBranchQuota(400_000);
    var entries: [latin1.len + legacy_other.len + greek_upper.len - 1 + greek_lower.len + others.len]Entry = undefined;
    var count: usize = 0;
    for (latin1, 0..) |name, index| {
        entries[count] = .{ .name = name, .cp = 0xa0 + index, .legacy = true };
        count += 1;
    }
    for (legacy_other) |pair| {
        entries[count] = .{ .name = pair[0], .cp = pair[1], .legacy = true };
        count += 1;
    }
    for (greek_upper, 0..) |name, index| if (name.len != 0) {
        entries[count] = .{ .name = name, .cp = 0x391 + index };
        count += 1;
    };
    for (greek_lower, 0..) |name, index| {
        entries[count] = .{ .name = name, .cp = 0x3b1 + index };
        count += 1;
    }
    for (others) |pair| {
        entries[count] = .{ .name = pair[0], .cp = pair[1] };
        count += 1;
    }
    std.debug.assert(count == entries.len);
    std.mem.sort(Entry, &entries, {}, lessThan);
    // A duplicate name would make the bisection result ambiguous.
    for (entries[1..], entries[0 .. entries.len - 1]) |next, previous| if (!lessThan({}, previous, next)) @compileError("duplicate entity name: " ++ next.name);
    const sorted = entries;
    break :blk sorted;
};
pub const max_name_bytes = 31;

fn find(name: []const u8) ?Entry {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, table[mid].name, name)) {
            .eq => return table[mid],
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

/// Exact, case-sensitive name without '&' and ';'.
pub fn lookup(name: []const u8) ?u21 {
    return if (find(name)) |entry| entry.cp else null;
}

/// `input` begins at '&'. A terminating semicolon is required except for the
/// HTML 4 Latin-1/markup names browsers also accept bare. A bare name must be
/// the complete alphanumeric run and must not precede '=', so query strings
/// such as "?a=1&copy=2" or "&region=x" keep their literal text.
pub fn named(input: []const u8, allow_bare: bool) ?Match {
    if (input.len < 3 or input[0] != '&') return null;
    var end: usize = 1;
    while (end < input.len and end <= max_name_bytes and std.ascii.isAlphanumeric(input[end])) end += 1;
    if (end == 1) return null;
    const entry = find(input[1..end]) orelse return null;
    if (end < input.len and input[end] == ';') return .{ .consumed = end + 1, .codepoint = entry.cp };
    if (!allow_bare or !entry.legacy or (end < input.len and input[end] == '=')) return null;
    return .{ .consumed = end, .codepoint = entry.cp };
}

/// The defined Windows-1252 characters at 0x80..0x9f; 0 marks undefined slots.
pub const cp1252_upper = [32]u21{
    0x20ac, 0,      0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
    0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0,      0x017d, 0,
    0,      0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
    0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0,      0x017e, 0x0178,
};
/// Browsers read numeric references 0x80..0x9f as Windows-1252. Undefined
/// slots stay C1 controls, which every display path already removes.
pub fn numericCodepoint(value: u21) u21 {
    if (value < 0x80 or value > 0x9f) return value;
    const mapped = cp1252_upper[value - 0x80];
    return if (mapped == 0) value else mapped;
}

test "html entities: sorted table resolves HTML4 names case-sensitively with bounded bare legacy names" {
    for (table[1..], table[0 .. table.len - 1]) |next, previous| try std.testing.expect(std.mem.order(u8, previous.name, next.name) == .lt);
    for ([_]Pair{ .{ "nbsp", 0xa0 }, .{ "yuml", 0xff }, .{ "Yuml", 0x178 }, .{ "szlig", 0xdf }, .{ "Agrave", 0xc0 }, .{ "agrave", 0xe0 }, .{ "Omega", 0x3a9 }, .{ "Sigma", 0x3a3 }, .{ "Rho", 0x3a1 }, .{ "sigmaf", 0x3c2 }, .{ "omega", 0x3c9 }, .{ "zwnj", 0x200c }, .{ "zwj", 0x200d }, .{ "lrm", 0x200e }, .{ "rlm", 0x200f }, .{ "ensp", 0x2002 }, .{ "emsp", 0x2003 }, .{ "thinsp", 0x2009 }, .{ "hairsp", 0x200a }, .{ "bdquo", 0x201e }, .{ "sbquo", 0x201a }, .{ "hellip", 0x2026 }, .{ "euro", 0x20ac }, .{ "check", 0x2713 }, .{ "diams", 0x2666 }, .{ "apos", '\'' }, .{ "AMP", '&' } }) |pair|
        try std.testing.expectEqual(@as(?u21, pair[1]), lookup(pair[0]));
    try std.testing.expect(lookup("NBSP") == null and lookup("unknown") == null and lookup("") == null);
    try std.testing.expectEqual(Match{ .consumed = 7, .codepoint = 0x2014 }, named("&mdash; tail", false).?);
    try std.testing.expectEqual(Match{ .consumed = 5, .codepoint = 0xa9 }, named("&copy 2026", true).?);
    try std.testing.expectEqual(Match{ .consumed = 4, .codepoint = '&' }, named("&amp", true).?);
    // Bare names need the opt-in, the legacy set and a complete name.
    try std.testing.expect(named("&copy 2026", false) == null);
    try std.testing.expect(named("&mdash tail", true) == null);
    try std.testing.expect(named("&copy=2", true) == null and named("&copyright", true) == null and named("&region=x", true) == null);
    try std.testing.expect(named("&;", true) == null and named("&", true) == null and named("& amp;", true) == null);
    try std.testing.expectEqual(@as(u21, 0x2019), numericCodepoint(0x92));
    try std.testing.expectEqual(@as(u21, 0x20ac), numericCodepoint(0x80));
    try std.testing.expectEqual(@as(u21, 0x81), numericCodepoint(0x81));
    try std.testing.expectEqual(@as(u21, 0xe9), numericCodepoint(0xe9));
}
