#!/usr/bin/env python3
"""Generate small, synthetic subtitle fixtures; does not contact Plex or launch a player."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
output = parser.parse_args().output
output.mkdir(parents=True, exist_ok=True)

samples = [
    ('Windows-1251', 'cp1251', 'ru', 'Съешь ещё этих мягких французских булок, да выпей чаю. Привет, мир! Русские субтитры должны читаться правильно.'),
    ('KOI8-R', 'koi8_r', 'ru', 'Съешь ещё этих мягких французских булок, да выпей чаю. Привет, мир! Русские субтитры должны читаться правильно.'),
    ('GB18030', 'gb18030', 'zh', '你好，世界！中文字幕应该正确显示。欢迎观看这部电影，这是简体中文字符测试。'),
    ('Big5', 'big5', 'zh', '你好，世界！中文字幕應該正確顯示。歡迎觀看這部電影，這是繁體中文字符測試。'),
    ('Shift-JIS', 'shift_jis', 'ja', 'こんにちは、世界！日本語の字幕が正しく表示されます。映画を楽しんでください。'),
    ('Windows-1256', 'cp1256', 'ar', 'مرحباً بالعالم! يجب عرض الترجمة العربية بشكل صحيح من اليمين إلى اليسار. أهلاً وسهلاً بكم.'),
    ('Windows-1255', 'cp1255', 'he', 'שלום עולם! כתוביות בעברית צריכות להופיע בצורה נכונה מימין לשמאל. ברוכים הבאים לסרט.'),
    ('ISO-8859-7', 'iso8859_7', 'el', 'Γειά σου κόσμε! Οι ελληνικοί υπότιτλοι πρέπει να εμφανίζονται σωστά. Καλή διασκέδαση.'),
    ('Windows-874', 'cp874', 'th', 'สวัสดีชาวโลก คำบรรยายภาษาไทยควรแสดงอย่างถูกต้อง ยินดีต้อนรับและขอให้สนุกกับภาพยนตร์'),
    ('ISO-8859-2', 'iso8859_2', 'pl', 'Zażółć gęślą jaźń. Polskie napisy powinny być wyświetlane poprawnie.'),
    ('UTF-8', 'utf8', 'en', 'Latin: Hello, world! Café — Привет, мир! Ελληνικά 中文 日本語 한국어 ไทย\nالعربية: مرحباً بالعالم! 123 (ABC)\nעברית: שלום עולם! 123 (ABC)'),
]

manifest = []
stem = "Dusk Subtitle Character Check (2026)"
for label, encoding, language, text in samples:
    name = f"{stem}.{label}.{language}.srt"
    body = f"1\n00:00:00,000 --> 00:00:05,000\n{text}\n"
    (output / name).write_bytes(body.encode(encoding))
    manifest.append(dict(file=name, encoding=encoding, expected=body))

# Preserve positioning, italic markup and an explicit Latin font in ASS.
ass = r"""[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Helvetica Neue,24,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,1,1,2,10,10,10,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,{\an8}Latin: Hello! {\i1}Привет!{\i0}\N中文 日本語 한국어 ไทย Ελληνικά\Nمرحباً بالعالم! 123 (ABC)\Nשלום עולם! 123 (ABC)
"""
(output / f"{stem}.UTF-8.ass").write_bytes(ass.encode("utf-8-sig"))
russian_ass = ass[:ass.index("Dialogue:")] + "Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,Привет, мир! Русские субтитры.\n"
(output / f"{stem}.Windows-1251.ru.ass").write_bytes(russian_ass.encode("cp1251"))
(output / f"{stem}.Windows-1251.ru.sub").write_bytes("{0}{120}Привет, мир! Русские субтитры.\n".encode("cp1251"))
mixed = samples[-1][3]
(output / f"{stem}.UTF-8.vtt").write_text(f"WEBVTT\n\n00:00.000 --> 00:05.000\n{mixed}\n", encoding="utf8")
(output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf8")
print(f"Wrote subtitle fixtures to {output}")
