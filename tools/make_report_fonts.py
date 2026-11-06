#!/usr/bin/env python3
"""Genera Sources/TeoStackCore/Reports/ReportFontData.swift e ReportSansMetrics.swift (font incorporati nei PDF).

Font (entrambi SIL Open Font License 1.1, vedi THIRD_PARTY_LICENSES.md):
  - JetBrains Mono (Regular, Bold, Italic): corpo dei report, 600/1000 em per carattere.
  - Inter (Regular, Bold; istanza statica di Inter[opsz,wght].ttf con opsz=14): titoli, data, piè di pagina, manuale.
Ridotti ai soli caratteri WinAnsi (CP1252), senza hinting né tabelle OpenType.

Uso: python3 tools/make_report_fonts.py <JetBrainsMono-Regular.ttf> <JetBrainsMono-Bold.ttf> <JetBrainsMono-Italic.ttf> <Inter[opsz,wght].ttf>
Richiede: pip install fonttools
"""
import base64, io, sys, os
from fontTools.ttLib import TTFont
from fontTools import subset
from fontTools.varLib import instancer

CP1252_EXTRAS = {0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6,
                 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C,
                 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A,
                 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178}

def code_to_unicode(code):
    if code in CP1252_EXTRAS: return CP1252_EXTRAS[code]
    return code

UNICODES = sorted({code_to_unicode(c) for c in range(0x20, 0x100) if c not in (0x7F, 0x81, 0x8D, 0x8F, 0x90, 0x9D)})

def subset_font(font):
    opts = subset.Options()
    opts.layout_features = []
    opts.hinting = False
    opts.notdef_outline = True
    opts.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14]
    opts.drop_tables += ["GSUB", "GPOS", "GDEF", "STAT", "MVAR", "HVAR", "avar", "fvar", "gvar", "cvar", "kern", "DSIG", "meta", "BASE"]
    opts.glyph_names = False
    sub = subset.Subsetter(opts)
    sub.populate(unicodes=UNICODES)
    sub.subset(font)
    out = io.BytesIO(); font.save(out)
    return out.getvalue()

def widths(font):
    cmap = font.getBestCmap(); hmtx = font["hmtx"]; upm = font["head"].unitsPerEm
    out = []
    for code in range(32, 256):
        u = code_to_unicode(code)
        name = cmap.get(u)
        out.append(round(hmtx[name][0] * 1000 / upm) if name else 0)
    return out

def b64_lines(data):
    s = base64.b64encode(data).decode()
    chunks = [s[i:i + 120] for i in range(0, len(s), 120)]
    return " +\n".join('        "' + c + '"' for c in chunks)

def metrics(font):
    h = font["hhea"]; o = font["OS/2"]; upm = font["head"].unitsPerEm; hd = font["head"]
    k = 1000 / upm
    return dict(ascent=round(h.ascent * k), descent=round(h.descent * k), cap=round(o.sCapHeight * k),
                bbox=[round(hd.xMin * k), round(hd.yMin * k), round(hd.xMax * k), round(hd.yMax * k)])

def main(argv):
    mono_regular, mono_bold, mono_italic, inter = argv[1:5]
    fonts = {}
    for key, path in (("monoRegular", mono_regular), ("monoBold", mono_bold), ("monoItalic", mono_italic)):
        f = TTFont(path)
        assert f["hmtx"]["A"][0] * 1000 // f["head"].unitsPerEm == 600, "il corpo deve essere monospazio a 600/1000 em"
        fonts[key] = f
    for key, wght in (("sansRegular", 400), ("sansBold", 700)):
        f = instancer.instantiateVariableFont(TTFont(inter), {"wght": wght, "opsz": 14})
        fonts[key] = f
    w = {k: widths(f) for k, f in fonts.items() if k.startswith("sans")}
    data = {k: subset_font(f) for k, f in fonts.items()}
    info = {k: metrics(TTFont(io.BytesIO(d))) for k, d in data.items()}      # riquadro del font calcolato sul font ridotto
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "TeoStackCore", "Reports")

    out = ["import Foundation", "",
           "/// Font incorporati nei PDF dei report e del manuale (generato da `tools/make_report_fonts.py`, non modificare a mano).",
           "/// - Corpo: JetBrains Mono (Regular, Bold, Italic), 600/1000 em per carattere.",
           "/// - Titoli, data, piè di pagina: Inter (Regular, Bold, istanza opsz 14).",
           "/// Entrambi con licenza SIL Open Font License 1.1, ridotti ai soli caratteri WinAnsi (CP1252). Vedi THIRD_PARTY_LICENSES.md.",
           "enum ReportFontData {"]
    names = [("regular", "monoRegular"), ("bold", "monoBold"), ("oblique", "monoItalic"), ("sansRegular", "sansRegular"), ("sansBold", "sansBold")]
    for swift, key in names:
        out.append(f"    static var {swift}: Data {{ Data(base64Encoded: {swift}Base64)! }}")
    out.append("")
    out.append("    /// Metriche dei descrittori PDF (1/1000 em): ascent, descent, altezza delle maiuscole, riquadro del font.")
    out.append("    struct Metrics { let ascent: Int; let descent: Int; let capHeight: Int; let bbox: [Int] }")
    for swift, key in names:
        m = info[key]
        out.append(f"    static let {swift}Metrics = Metrics(ascent: {m['ascent']}, descent: {m['descent']}, capHeight: {m['cap']}, bbox: {m['bbox']})")
    out.append("")
    for swift, key in names:
        out.append(f"    private static let {swift}Base64 =\n{b64_lines(data[key])}\n")
    out.append("}")
    open(os.path.join(root, "ReportFontData.swift"), "w").write("\n".join(out) + "\n")

    def arr(vals):
        rows = [", ".join(str(v) for v in vals[i:i + 16]) for i in range(0, len(vals), 16)]
        return "[\n        " + ",\n        ".join(rows) + ",\n    ]"
    m = ["/// Larghezze dei glifi (1/1000 em) di Inter Regular e Bold per i codici WinAnsi (CP1252) 32...255 (generato da `tools/make_report_fonts.py`).",
         "/// Servono a misurare il testo dei titoli per impaginarlo.",
         "enum ReportSansMetrics {",
         f"    static let regular: [Int] = {arr(w['sansRegular'])}",
         f"    static let bold: [Int] = {arr(w['sansBold'])}",
         "}"]
    open(os.path.join(root, "ReportSansMetrics.swift"), "w").write("\n".join(m) + "\n")
    for k, d in data.items(): print(k, len(d), "byte", info[k])

main(sys.argv)
