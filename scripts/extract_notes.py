import json, re, sys
import pypdf

PDF, OUT = sys.argv[1], sys.argv[2]

# canonical title, then aliases as they appear in the text (after fix_thai)
TITLES = [
    ("สาธุการ", []), ("ตระหญ้าปากคอก", []), ("รัวสามลา", []),
    ("ต้นเข้าม่าน (ชุบ)", ["ต้นเข้าม่าน(ชุบ)"]), ("เข้าม่าน", []), ("ปฐม", []),
    ("ลา", []), ("เสมอ", []), ("รัวลาเดียว", []),
    ("เชิดสองชั้น (เชิดฉิ่ง)", ["เชิดสองชั้น"]), ("เชิดชั้นเดียว (เชิดกลอง)", ["เชิดชั้นเดียว"]),
    ("กลม", []), ("ชำนาญ", []), ("กราวใน", []), ("เหาะ", []),
    ("สาธุการกลอง", []), ("ตระบองกัน", []), ("ตระสันนิบาต", []), ("ตระเชิญ", []),
    ("บาทสกุณี (เสมอตีนนก)", ["บาทสกุณี"]), ("ตระประทานพร", []),
    ("ตระเทวาประสิทธิ์", []), ("เสมอเถร", []), ("เสมอผี", []), ("เสมอมาร", []),
    ("ตระพระประคนธรรพ", []), ("แผละ", []), ("พราหมณ์เข้า", []),
    ("ตระนารายณ์บรรทมสินธุ์", []), ("ตระพระวิษณุกรรม", []), ("ลงสรง", []),
    ("โปรยข้าวตอกดอกไม้", []), ("พราหมณ์ออก", ["พรามหณ์ออก"]), ("เสมอเข้าที่", []),
    ("กราวรำ", []), ("ตระกริ่ง (ตระหริ่ง)", ["ตระกริ่ง"]), ("ตระมงคลจักรวาล", []),
    ("ตระประสิทธิ์", []), ("ตระพระคเณศ (พิฆเนศ)", ["ตระพระคเณศ"]),
    ("ตระพระฤาษีกลัยโกศ (กไลยโกฏิ)", ["ตระพระฤาษีกลัยโกศ"]), ("ตระบรรทมไพร", []),
    ("ตระเชิญเหนือเชิญใต้", []), ("เสมอ 3 ลา", []), ("ดำเนินพราหมณ์", []),
    ("ต้นเสมอ", []), ("เสมอพราหมณ์", []), ("โคมเวียน", []), ("ตระนิมิต", []),
    ("พระเจ้าลอยถาด", []), ("ปลายเข้าม่าน", []), ("ลา ๒ ชั้น", []),
    ("เสมอข้ามสมุทร", []), ("คุกพาทย์", []), ("ตระนาง", []), ("เทพดำเนิน", []),
    ("เสมอเข้าเฝ้า", []), ("สระสมลูกศิษย์", []), ("ตระพระปัญจะสิงขร", []),
    ("ตระนางเดิน", []), ("ตระพระอุมา", []), ("ตระพระนารายณ์", []), ("ตระพระพรหม", []),
    ("รำดาบ (เชือดหัวหมู)", ["รำดาบ(เชือดหัวหมู)"]), ("ตระนาฏราช", []), ("ตระนอน", []),
    ("กราวนอก", []), ("มหาฤกษ์ทางไทย", []), ("มหาชัยทางไทย", []),
    ("นั่งกิน", []), ("เซ่นเหล้า", []),
]
MATCHERS = sorted(
    [(alias, canon) for canon, al in TITLES for alias in [canon] + al],
    key=lambda x: -len(x[0]),
)
SECTION_RE = re.compile(
    r"^\*?(ท่อน\s*\S+|ตัว\s*\d+|วรรค\s*\S+|เนื้อวรรค\s*\S+|เสียงที่\s*\d+|ลาที่\s*\d+|"
    r"สร้อย.*|ลูกนำ|นำ|ท้ายปฐม|เที่ยวกลับ|รัวเฉพาะ.*|รัวตัด|มโนราห์|เร่งเร็ว.*|"
    r"สาธุการ เปิดโลก.*|เปิดโลก.*)$"
)
NOTE_TOKEN = re.compile(r"^\*?[-ดรมฟซลทบฺุู่้๊๋์0-9๐-๙*]+$")
HAS_NOTE = re.compile(r"[-ดรมฟซลท]")
NUM = re.compile(r"^[0-9๐-๙]+$")
THAI_DIGITS = str.maketrans("๐๑๒๓๔๕๖๗๘๙", "0123456789")


def fix_thai(s):
    # broken sara am ("ค าน า" -> "คำนำ") and shifted marks under tall consonants
    s = re.sub(r"(?<=[ก-ฮ่้๊๋]) า", "ำ", s)
    s = re.sub(r"(?<=[ปฝฟ])ู", "้", s)
    s = re.sub(r"(?<=[ปฝฟ])ุ", "่", s)
    return s


def is_note_token(t):
    return bool(NOTE_TOKEN.match(t)) and bool(HAS_NOTE.search(t))


def parse_note_line(line):
    # "(ล้อ)" (echo) marks belong to the measure before them
    line_n = re.sub(r"\s+\(ล้อ\)", "(ล้อ)", line)
    toks = line_n.split()
    number = None
    if len(toks) >= 2 and NUM.match(toks[-1]):
        number = int(toks[-1].translate(THAI_DIGITS))
        toks = toks[:-1]
    core = lambda t: t.replace("(ล้อ)", "")
    prefix = []
    while toks and not is_note_token(core(toks[0])):
        prefix.append(toks.pop(0))
    if not toks:
        return None
    notes = [t for t in toks if is_note_token(core(t))]
    if len(notes) < 2 and prefix:
        return None
    if len(notes) / len(toks) < 0.6:
        return None
    # keep short typo'd measures (e.g. "ทฃรด") in place; longer words are remarks
    measures, remarks = [], []
    for t in toks:
        if is_note_token(core(t)) or (len(core(t)) <= 5 and HAS_NOTE.search(t)):
            measures.append(t)
        else:
            remarks.append(t)
    item = {"type": "notes", "measures": measures}
    if number is not None:
        item["line"] = number
    if prefix:
        item["instruction"] = " ".join(prefix)
    if remarks:
        item["remarks"] = " ".join(remarks)
    item["raw"] = line
    return item


def match_title(line):
    for alias, canon in MATCHERS:
        if line.startswith(alias):
            rest = line[len(alias):]
            if rest == "" or rest[0] in " (*":
                return canon, rest.strip(" *")
    return None


INLINE_SEC = re.compile(r"(ท่อน\s*[0-9๐-๙]+|เปิดโลก|เสียงที่\s*\d+|เที่ยวกลับ)(\s*\(ต่อ\))?")
# photo captions and section dividers that are not part of any song
SKIP_PREFIX = ("ภาพครู", "ยืนด้านหลัง", "กราบขอบพระคุณ อาจารย์อานันท์", "ภาคสอง", "เพลงชุดโหมโรง")
# general commentary paragraph (p.49) runs until the next song heading
COMMENTARY_START = ("เพลงหน้าพาทย์ ที่บันทึกเป็นโน้ตสากล",)

reader = pypdf.PdfReader(PDF)
songs, song, section = [], None, None
editor_notes, commentary = [], False


def new_section(name):
    global section
    name = name.replace("(ต่อ)", "").strip() if name else name
    if section is not None and name and section["name"] == name:
        return  # continuation heading
    section = {"name": name, "items": []}
    song["sections"].append(section)


def add_item(item):
    if section is None:
        new_section(None)
    section["items"].append(item)


for pno in range(14, 90):  # song pages; 90+ are image/index
    text = fix_thai(reader.pages[pno - 1].extract_text() or "")
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    if lines and NUM.match(lines[0]):
        lines = lines[1:]  # page number header
    for line in lines:
        line = re.sub(r"\s+", " ", line)
        if line.startswith(SKIP_PREFIX) or "(มีแล้วในโหมโรงเย็น)" in line:
            continue
        if line.startswith(COMMENTARY_START):
            commentary = True
        m = match_title(line)
        if commentary and not (m and m[1] == ""):
            editor_notes.append({"page": pno, "text": line})
            continue
        commentary = False
        if m:
            canon, rest = m
            if song and song["title"] == canon and song["pages"][-1] >= pno - 1:
                pass  # repeated heading on continuation
            else:
                song = {"title": canon, "part": 2 if pno >= 41 else 1,
                        "pages": [], "heading": line, "sections": []}
                songs.append(song)
                section = None
            if pno not in song["pages"]:
                song["pages"].append(pno)
            if rest:
                sm = INLINE_SEC.search(rest)
                if sm:
                    new_section(sm.group(1).strip())
                    extra = (rest[:sm.start()] + " " + rest[sm.end():]).strip()
                    if extra:
                        add_item({"type": "text", "text": extra})
                else:
                    add_item({"type": "text", "text": rest})
            continue
        if song is None:
            continue
        if pno not in song["pages"]:
            song["pages"].append(pno)
        if NUM.match(line):
            # stray line number from a vertically-split row (e.g. p.16)
            for it in reversed(section["items"] if section else []):
                if it["type"] == "notes":
                    it.setdefault("line", int(line.translate(THAI_DIGITS)))
                    break
            continue
        note = parse_note_line(line)
        if note:
            add_item(note)
        elif SECTION_RE.match(line.split(" (")[0].replace("(ต่อ)", "").strip()):
            head, _, extra = line.lstrip("*").partition(" (")
            new_section(head.strip())
            if extra and extra.strip() != "ต่อ)":
                add_item({"type": "text", "text": "(" + extra})
        else:
            add_item({"type": "text", "text": line})

# headings with no notation (e.g. the โหมโรงเช้า list on p.39, "รัวลาเดียว" as
# an exit instruction) are folded back into the previous song as text
merged = []
for s in songs:
    has_notes = any(i["type"] == "notes" for sec in s["sections"] for i in sec["items"])
    if not has_notes and merged:
        prev = merged[-1]
        prev["sections"][-1]["items"].append({"type": "text", "text": s["heading"]})
        for sec in s["sections"]:
            prev["sections"][-1]["items"].extend(sec["items"])
        for p in s["pages"]:
            if p not in prev["pages"]:
                prev["pages"].append(p)
    else:
        merged.append(s)

seen = {}
for i, s in enumerate(merged, 1):
    seen[s["title"]] = seen.get(s["title"], 0) + 1
    s["id"] = i
    s["occurrence"] = seen[s["title"]]
    s["note_line_count"] = sum(1 for sec in s["sections"] for it in sec["items"] if it["type"] == "notes")
    s["group"] = "เพลงชุดโหมโรงเช้า" if s["title"] == "เหาะ" else (
        "เพลงชุดโหมโรงเย็น" if s["part"] == 1 else "เพลงประกอบพิธีไหว้ครู")

out = {
    "source": "โน้ตเพลงไทย ๑๐ แผ่นดิน ฉบับเพลงครู (eBOOK).pdf",
    "author": "ต้นฉบับลายมือ ครูขุน พงษ์ผล / รวบรวมโดย คมสันต์ สุทนต์",
    "notation": {
        "description": "โน้ตตัวอักษรไทย 1 ห้อง = 4 ตัว ('-' = ไม่ตี), 1 บรรทัดปกติ = 8 ห้อง",
        "pitches": ["ด", "ร", "ม", "ฟ", "ซ", "ล", "ท"],
        "marks_kept_as_is": "เครื่องหมายเช่น ฺ ่ และตัวเลขต่อท้ายตัวโน้ต (ร4, ล8) เก็บไว้ตามต้นฉบับใน measures",
    },
    "image_only_pages": [13, 40, 75, 90],
    "editor_notes": editor_notes,
    "song_count": len(merged),
    "songs": [{k: s[k] for k in ["id", "title", "occurrence", "part", "group", "pages",
                                  "heading", "note_line_count", "sections"]} for s in merged],
}
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, indent=1)
for s in merged:
    print(s["id"], s["title"], s["occurrence"], s["pages"], s["note_line_count"],
          [sec["name"] for sec in s["sections"]])
